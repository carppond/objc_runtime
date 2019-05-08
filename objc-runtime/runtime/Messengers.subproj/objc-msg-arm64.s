/*
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Copyright (c) 2011 Apple Inc.  All Rights Reserved.
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */
/********************************************************************
 * 
 *  objc-msg-arm64.s - ARM64 code to support objc messaging
 *
 ********************************************************************/

#ifdef __arm64__

#include <arm/arch.h>
#include "isa.h"
#include "arm64-asm.h"

.data

// _objc_entryPoints and _objc_exitPoints are used by method dispatch
// caching code to figure out whether any threads are actively 
// in the cache for dispatching.  The labels surround the asm code
// that do cache lookups.  The tables are zero-terminated.

.align 4
.private_extern _objc_entryPoints
_objc_entryPoints:
	PTR   _cache_getImp
	PTR   _objc_msgSend
	PTR   _objc_msgSendSuper
	PTR   _objc_msgSendSuper2
	PTR   _objc_msgLookup
	PTR   _objc_msgLookupSuper2
	PTR   0

.private_extern _objc_exitPoints
_objc_exitPoints:
	PTR   LExit_cache_getImp
	PTR   LExit_objc_msgSend
	PTR   LExit_objc_msgSendSuper
	PTR   LExit_objc_msgSendSuper2
	PTR   LExit_objc_msgLookup
	PTR   LExit_objc_msgLookupSuper2
	PTR   0


/* objc_super parameter to sendSuper */
#define RECEIVER         0
#define CLASS            __SIZEOF_POINTER__

/* Selected field offsets in class structure */
#define SUPERCLASS       __SIZEOF_POINTER__
/// __SIZEOF_POINTER__ 8 个字节，所以 cache 是 16 个字节
#define CACHE            (2 * __SIZEOF_POINTER__)

/* Selected field offsets in method structure */
#define METHOD_NAME      0
#define METHOD_TYPES     __SIZEOF_POINTER__
#define METHOD_IMP       (2 * __SIZEOF_POINTER__)

#define BUCKET_SIZE      (2 * __SIZEOF_POINTER__)


/********************************************************************
 * GetClassFromIsa_p16 src
 * src is a raw isa field. Sets p16 to the corresponding class pointer.
 * The raw isa might be an indexed isa to be decoded, or a
 * packed isa that needs to be masked.
 *
 * On exit:
 *   $0 is unchanged
 *   p16 is a class pointer
 *   x10 is clobbered
 ********************************************************************/

#if SUPPORT_INDEXED_ISA
	.align 3
	.globl _objc_indexed_classes
_objc_indexed_classes:
	.fill ISA_INDEX_COUNT, PTRSIZE, 0
#endif

.macro GetClassFromIsa_p16 /* src */

#if SUPPORT_INDEXED_ISA
	// Indexed isa
	mov	p16, $0			// optimistically set dst = src
	tbz	p16, #ISA_INDEX_IS_NPI_BIT, 1f	// done if not non-pointer isa
	// isa in p16 is indexed
	adrp	x10, _objc_indexed_classes@PAGE
	add	x10, x10, _objc_indexed_classes@PAGEOFF
	ubfx	p16, p16, #ISA_INDEX_SHIFT, #ISA_INDEX_BITS  // extract index
	ldr	p16, [x10, p16, UXTP #PTRSHIFT]	// load class from array
1:

#elif __LP64__
	// 64-bit packed isa
	and	p16, $0, #ISA_MASK

#else
	// 32-bit raw isa
	mov	p16, $0

#endif

.endmacro


/********************************************************************
 * ENTRY functionName
 * STATIC_ENTRY functionName
 * END_ENTRY functionName
 ********************************************************************/

.macro ENTRY /* name */
	.text
	.align 5
	.globl    $0
$0:
.endmacro

.macro STATIC_ENTRY /*name*/
	.text
	.align 5
	.private_extern $0
$0:
.endmacro

.macro END_ENTRY /* name */
LExit$0:
.endmacro


/********************************************************************
 * UNWIND name, flags
 * Unwind info generation	
 ********************************************************************/
.macro UNWIND
	.section __LD,__compact_unwind,regular,debug
	PTR $0
	.set  LUnwind$0, LExit$0 - $0
	.long LUnwind$0
	.long $1
	PTR 0	 /* no personality */
	PTR 0  /* no LSDA */
	.text
.endmacro

#define NoFrame 0x02000000  // no frame, no SP adjustment
#define FrameWithNoSaves 0x04000000  // frame, no non-volatile saves


/********************************************************************
 *
 * CacheLookup NORMAL|GETIMP|LOOKUP
 * 在类方法缓存中找到方法的细线
 * Locate the implementation for a selector in a class method cache.
 *
 * Takes:
 *	 x1 = selector
 *	 x16 = class to be searched
 *
 * Kills:
 * 	 x9,x10,x11,x12, x17
 *
 * On exit: (found) calls or returns IMP
 *                  with x16 = class, x17 = IMP
 *          (not found) jumps to LCacheMiss
 *
 ********************************************************************/

#define NORMAL 0
#define GETIMP 1
#define LOOKUP 2

// CacheHit: x17 = cached IMP, x12 = address of cached IMP
.macro CacheHit
.if $0 == NORMAL
	TailCallCachedImp x17, x12	// authenticate and call imp
.elseif $0 == GETIMP
	mov	p0, p17
	AuthAndResignAsIMP x0, x12	// authenticate imp and re-sign as IMP
	ret				// return IMP
.elseif $0 == LOOKUP
	AuthAndResignAsIMP x17, x12	// authenticate imp and re-sign as IMP
	ret				// return imp via x17
.else
.abort oops
.endif
.endmacro

.macro CheckMiss
	// miss if bucket->sel == 0
.if $0 == GETIMP
	cbz	p9, LGetImpMiss
.elseif $0 == NORMAL
	cbz	p9, __objc_msgSend_uncached
.elseif $0 == LOOKUP
	cbz	p9, __objc_msgLookup_uncached
.else
.abort oops
.endif
.endmacro

.macro JumpMiss
.if $0 == GETIMP
	b	LGetImpMiss
.elseif $0 == NORMAL
	b	__objc_msgSend_uncached
.elseif $0 == LOOKUP
	b	__objc_msgLookup_uncached
.else
.abort oops
.endif
.endmacro

.macro CacheLookup
    /*
     ldp 取值指令，出栈指令，这里从 x16 + CACHE 指向的地址里面取出 2 个 64 位的值，分别存进 x10 和 x11 中
     CACHE 的定义在本文件中可以中找到 16 个字节
     因为 iOS 属于小端，所以高 32 位存了 occupied,第s 32 位存了 mask
     查找过程：
     x16 是类的地址
     objc-runtime-new.h
     
     struct objc_class : objc_object {
        // Class ISA;
        Class superclass;
        cache_t cache;             // formerly cache pointer and vtable
        class_data_bits_t bits;    // class_rw_t * plus custom rr/alloc flags
     
        class_rw_t *data() {
        return bits.data();
        ........
     }
     superclass 偏移量是 8，cache偏移量是 16，cache_t的结构体如下：
     
     struct cache_t {
        struct bucket_t *_buckets;
        mask_t _mask;
        mask_t _occupied;
     
        public:
        struct bucket_t *buckets();
        mask_t mask();
        mask_t occupied();
        void incrementOccupied();
        void setBucketsAndMask(struct bucket_t *newBuckets, mask_t newMask);
        void initializeToEmpty();
        .........
     };
     所以'x16 + CACHE 指向的地址里面取出 2 个 64 位的值'，x10 存去的_buckets，p11 高 32 位存了 occupied,第s 32 位存了 mask
     _buckets 缓存函数地址,实际上是一个哈希表
    _mask 是 2 的n次-1 次幂，也就是0x000000001111111,通过它和函数方法可以求出函数在哈希表中的索引。
     */
	// p1 = SEL, p16 = isa
	ldp	p10, p11, [x16, #CACHE]	// p10 = buckets, p11 = occupied|mask
#if !__LP64__
    /// 32 位 x11 & 0xffff 赋值给 x11,jiu
	and	w11, w11, 0xffff	// p11 = mask
#endif
    /// 函数 & mask = x12，其实就是 _cmd % mask的大小，这里主要是获取函数方法在哈希表中的索引
	and	w12, w1, w11		// x12 = _cmd & mask
    /*
     PTRSHIFT 定义在 arm64-asm.h 中，其实就是个 3，
     x10 是 _buckets 的首地址
     x12 左移 4 位，也就是乘以16，这是因为哈希表中的 bucket 是 16 个字节,计算得出第一个bucket地址，保存到 x12 中
     */
	add	p12, p10, p12, LSL #(1+PTRSHIFT)
		             // p12 = buckets + ((_cmd & mask) << (1+PTRSHIFT))
    /*
     将 bucket 分别白村到 x17 和 x9 中
     struct bucket_t {
        private:
        // IMP-first is better for arm64e ptrauth and no worse for arm64.
        // SEL-first is better for armv7* and i386 and x86_64.
        #if __arm64__
            MethodCacheIMP _imp;
            cache_key_t _key;
        #else
            cache_key_t _key;
            MethodCacheIMP _imp;
        #endif
        ......
     }
     从上面的定义中可以发现，x17 存的是 imp，x9 存的是 key,而 key 世界上是 sel
     */
	ldp	p17, p9, [x12]		// {imp, sel} = *bucket
    /*
     比较找到的 x9 sel 和传入的 sel，如果一样就跳转到CacheHit，如果不一样就继续查找。
     // CacheHit: x17 = cached IMP, x12 = address of cached IMP
     .macro CacheHit
     .if $0 == NORMAL
     TailCallCachedImp x17, x12    // authenticate and call imp
     .elseif $0 == GETIMP
     mov    p0, p17
     AuthAndResignAsIMP x0, x12    // authenticate imp and re-sign as IMP
     ret                // return IMP
     .elseif $0 == LOOKUP
     AuthAndResignAsIMP x17, x12    // authenticate imp and re-sign as IMP
     ret                // return imp via x17
     .else
     .abort oops
     .endif
     .endmacro
     由于这里传入的是 NORMAL，所以执行  TailCallCachedImp x17, x12,x12存了缓存的 imp 地址，x17 存了 imp，这里是验证并调用 缓存的函数imp
     */
1:	cmp	p9, p1			// if (bucket->sel != _cmd)
	b.ne	2f			//     scan more
	CacheHit $0			// call or return imp

    /*
     .macro CheckMiss
     // miss if bucket->sel == 0
     .if $0 == GETIMP
     cbz    p9, LGetImpMiss
     .elseif $0 == NORMAL
     cbz    p9, __objc_msgSend_uncached
     .elseif $0 == LOOKUP
     cbz    p9, __objc_msgLookup_uncached
     .else
     .abort oops
     .endif
     .endmacro
     
     由于 $0 = NORMAL,所以这里要执行  cbz    p9, __objc_msgSend_uncached，判断找到的 x9 sel 是否为空(0)，如果是就跳转到__objc_msgSend_uncached，之后会调用 __class_lookupMethodAndLoadCache3 这个 C 函数进行更加复杂的查找,_
     _class_lookupMethodAndLoadCache3 的实现在 objc-runtime-new.mm 中
     */
2:	// not hit: p12 = not-hit bucket
	CheckMiss $0			// miss if bucket->sel == 0
    /// 比较找出的bucket 和 buckets
	cmp	p12, p10		// wrap if bucket == buckets
    /// 如果相等，就说明找到的bucket是buckets的首地址,跳转到 3,如果不相等就倒序，跳到 1，继续寻找
	b.eq	3f
    /// x12 != x10 .到这里执行，倒序查找前一个bucket,x17 是前一个bucket的 imp，x9 是前一个bucket的 sel
	ldp	p17, p9, [x12, #-BUCKET_SIZE]!	// {imp, sel} = *--bucket
    /// 跳转到 1 继续执行
	b	1b			// loop

    /*
     调用到这里说明 bucket 是 buckets 的第一个
     x12 是第一个第一个 bucket，x11 存储的是当前 mask 表的大小
     这里是把指针指向最后一个 bucket，赋值给 x12
     */
3:	// wrap: p12 = first bucket, w11 = mask
	add	p12, p12, w11, UXTW #(1+PTRSHIFT)
		                        // p12 = buckets + (mask << 1+PTRSHIFT)

	// Clone scanning loop to miss instead of hang when cache is corrupt.
	// The slow path may detect any corruption and halt later.

    /// x 17 是最后一个 bucket 的 imp，x9 是最后一个 bucket 的 sel
	ldp	p17, p9, [x12]		// {imp, sel} = *bucket
    /// 判断 x9 和 传入的参数_cmd(函数)是否相同
1:	cmp	p9, p1			// if (bucket->sel != _cmd)
    /// 如果 x9 和传入的参数_cmd 就执行CacheHit，不相同就跳转到 2：
	b.ne	2f			//     scan more
    /// CacheHit的逻辑和上面的相同
	CacheHit $0			// call or return imp

    /// CheckMiss 与 上面的 CheckMiss 相同
2:	// not hit: p12 = not-hit bucket
	CheckMiss $0			// miss if bucket->sel == 0
    /// 比较x12 和 x10，x12 是最后一个 bucket
	cmp	p12, p10		// wrap if bucket == buckets
    /// 如果最后一个bucket和 x10 相等，就跳转到 3：不相等继续执行
	b.eq	3f
    /// 获取前一个bucket，x17 即前一个 bucket 的 imp，x9 即前一个 bucket 的 sel
	ldp	p17, p9, [x12, #-BUCKET_SIZE]!	// {imp, sel} = *--bucket
    /// 跳转到 1 继续执行
	b	1b			// loop

    /*
     .macro JumpMiss
     .if $0 == GETIMP
     b    LGetImpMiss
     .elseif $0 == NORMAL
     b    __objc_msgSend_uncached
     .elseif $0 == LOOKUP
     b    __objc_msgLookup_uncached
     .else
     .abort oops
     .endif
     .endmacro
     
     由于 $0 = NORMAL,所以这里要执行  cbz    p9, __objc_msgSend_uncached，判断找到的 x9 sel 是否为空(0)，如果是就跳转到__objc_msgSend_uncached，之后会调用 __class_lookupMethodAndLoadCache3 这个 C 函数进行更加复杂的查找,_
     _class_lookupMethodAndLoadCache3 的实现在 objc-runtime-new.mm 中
     */
3:	// double wrap
	JumpMiss $0

    /*
     CheckMiss 和 JumpMiss 的 sel 为空，也就是没有找到缓存的 sel,都会调用 __class_lookupMethodAndLoadCache3
     __class_lookupMethodAndLoadCache3 的实现在 objc-runtime-new.mm 中
     
     */
.endmacro
/*
 参考文章：
 [欧阳大哥](https://www.jianshu.com/p/df6629ec9a25)
 [objc-msg-arm64源码深入分析](https://chipengliu.github.io/2019/04/07/objc-msg-armd64/)
 [逐行剖析objc_msgSend汇编源码](https://www.jianshu.com/p/92d3fe62014d)
 [](http://yulingtianxia.com/blog/2016/06/15/Objective-C-Message-Sending-and-Forwarding/)
 */

/********************************************************************
 *
 * id objc_msgSend(id self, SEL _cmd, ...);
 * IMP objc_msgLookup(id self, SEL _cmd, ...);
 * 
 * objc_msgLookup ABI:
 * IMP returned in x17
 * x16 reserved for our use but not used
 *
 ********************************************************************/

#if SUPPORT_TAGGED_POINTERS
	.data
	.align 3
	.globl _objc_debug_taggedpointer_classes
_objc_debug_taggedpointer_classes:
	.fill 16, 8, 0
	.globl _objc_debug_taggedpointer_ext_classes
_objc_debug_taggedpointer_ext_classes:
	.fill 256, 8, 0
#endif

	ENTRY _objc_msgSend  /// objc_msgSend 的入口
	UNWIND _objc_msgSend, NoFrame

    /*
     空检测和标记指针检查
     x0是消息接收者接收者receiver,或者上方注释的 self
     cmp 比较指令
     对象是否为空检查和receiver 是否是 tagged pointer 类型
     */
	cmp	p0, #0			// nil check and tagged pointer check
    /// 如何支持 tagged pointer 类型，就调用LNilOrTagged
#if SUPPORT_TAGGED_POINTERS
    /// b 跳转指令，le 是小于等于指令，也就是判断 x0 小于等于 0 时，跳转到 LNilOrTagged
	b.le	LNilOrTagged		//  (MSB tagged pointer looks negative)
#else
    /*
     x0 不支持 tagged pointer 类型执行 b.eq    LReturnZero
     b 跳转，eq 等于，判断 x0 是否等于 nil 就是判断接收者 receiver 为空，如果为空就退出这个函数，不为空就继续执行
     */
	b.eq	LReturnZero
#endif
    /// x13 = isa，把 receiver 的指针赋值到 x13 中，因为 receiver 是 objc_object 结构体，结构体的第一个属性就是 isa，所以这里的 isa 指向了 isa
	ldr	p13, [x0]		// p13 = isa
    /// 从 x13 指针中获取类的指针存进x16
	GetClassFromIsa_p16 p13		// p16 = class
LGetIsaDone:
    /// 去缓存中z查找
    /*
     CacheLookup 的逻辑大约为：
     bucket bucket = class->cache->buckets[sel];
     if (sel == bucket->key) {
        bucket->imp();
     }
     else {
        /// 调用 '__class_lookupMethodAndLoadCache3' 进行更加复杂的 C 语言查找
     }
     */
	CacheLookup NORMAL		// calls imp or objc_msgSend_uncached

#if SUPPORT_TAGGED_POINTERS
LNilOrTagged:
    /// 判断接收者 receiver 为空，如果为空就退出这个函数，不为空就继续执行
	b.eq	LReturnZero		// nil check

	// tagged
    /*
     这里加载了 _objc_debug_taggedpointer_classes 的地址，即 Tagged Pointer 主表
     ARM64 需要两条指令来加载一个符号的地址。这是 RISC 样架构上的一个标准技术。
     AMR64 上的指针是 64 位宽的，指令是 32 位宽。所以一个指令无法保存一个完整的指针
     */
    /// 将页的前半部分基地址存到 x10
	adrp	x10, _objc_debug_taggedpointer_classes@PAGE
    /// 将页的后半部分基地址加上 x10，得到一个新地址，新地址存到 x10，以上是获取一个完成的地址
	add	x10, x10, _objc_debug_taggedpointer_classes@PAGEOFF
    ///ubfx 无符号提取指令，这句话的意思是:从 receiver 的第 60 位开始，提取 4 位，保存到 x11 中，也可以翻译成：x11 = (x0 & xF00)>>60，将类中的 index 从 receiver 中提取保存到 x11
    ubfx	x11, x0, #60, #4
    /// 翻译成：x16 = x10 + x11 << 3，这里其实是通过 x11 的索引去 x10 里找到 Tagged Pointer 表中具体的类,然后保存进 x16
	ldr	x16, [x10, x11, LSL #3]///

	adrp	x10, _OBJC_CLASS_$___NSUnrecognizedTaggedPointer@PAGE
	add	x10, x10, _OBJC_CLASS_$___NSUnrecognizedTaggedPointer@PAGEOFF
    /// 以上代码是获取类_NSUnrecognizedTaggedPointer
    /// 这里是比较上面获取的类 x16 和 x10
	cmp	x10, x16
    /// 如果 x10 和 x16 两个类不相等就跳转到 LGetIsaDone ，相等就继续执行
	b.ne	LGetIsaDone

    // ext tagged  : extension
    /// 这里是对扩展的 tagged pointer 类
    /// 下面两行是将扩展的类加载进 x10
	adrp	x10, _objc_debug_taggedpointer_ext_classes@PAGE
	add	x10, x10, _objc_debug_taggedpointer_ext_classes@PAGEOFF
    /// 与以上类似：将扩展类的 index 从 receiver 中取出，然后保存进 x11
	ubfx	x11, x0, #52, #8
    ///  翻译成：x16 = x10 + x11 << 3，这里其实是通过 x11 的索引去 x10 里找到扩展表中具体的类,然后保存进 x16
	ldr	x16, [x10, x11, LSL #3]
    /// 跳转到主程序 LGetIsaDone
	b	LGetIsaDone
// SUPPORT_TAGGED_POINTERS
#endif

LReturnZero:
	// x0 is already zero
    /// 到这里 receiver 已经是空，这里把 x1 置空
    // 整型的返回值保存在 x0 和 x1 中
    // 浮点型的返回值会被保存在 v0 到 v3 这几个向量寄存器中，
    // d0 到 d3这几个寄存器是相关v寄存器的后半部分，向他们存值的时候会将对应 v 寄存器的前半部分置 0
	mov	x1, #0
	movi	d0, #0
	movi	d1, #0
	movi	d2, #0
	movi	d3, #0
	ret

	END_ENTRY _objc_msgSend


	ENTRY _objc_msgLookup
	UNWIND _objc_msgLookup, NoFrame
	cmp	p0, #0			// nil check and tagged pointer check
#if SUPPORT_TAGGED_POINTERS
	b.le	LLookup_NilOrTagged	//  (MSB tagged pointer looks negative)
#else
	b.eq	LLookup_Nil
#endif
	ldr	p13, [x0]		// p13 = isa
	GetClassFromIsa_p16 p13		// p16 = class
LLookup_GetIsaDone:
	CacheLookup LOOKUP		// returns imp

#if SUPPORT_TAGGED_POINTERS
LLookup_NilOrTagged:
	b.eq	LLookup_Nil	// nil check

	// tagged
	mov	x10, #0xf000000000000000
	cmp	x0, x10
	b.hs	LLookup_ExtTag
	adrp	x10, _objc_debug_taggedpointer_classes@PAGE
	add	x10, x10, _objc_debug_taggedpointer_classes@PAGEOFF
	ubfx	x11, x0, #60, #4
	ldr	x16, [x10, x11, LSL #3]
	b	LLookup_GetIsaDone

LLookup_ExtTag:	
	adrp	x10, _objc_debug_taggedpointer_ext_classes@PAGE
	add	x10, x10, _objc_debug_taggedpointer_ext_classes@PAGEOFF
	ubfx	x11, x0, #52, #8
	ldr	x16, [x10, x11, LSL #3]
	b	LLookup_GetIsaDone
// SUPPORT_TAGGED_POINTERS
#endif

LLookup_Nil:
	adrp	x17, __objc_msgNil@PAGE
	add	x17, x17, __objc_msgNil@PAGEOFF
	ret

	END_ENTRY _objc_msgLookup

	
	STATIC_ENTRY __objc_msgNil

	// x0 is already zero
	mov	x1, #0
	movi	d0, #0
	movi	d1, #0
	movi	d2, #0
	movi	d3, #0
	ret
	
	END_ENTRY __objc_msgNil


	ENTRY _objc_msgSendSuper
	UNWIND _objc_msgSendSuper, NoFrame

	ldp	p0, p16, [x0]		// p0 = real receiver, p16 = class
	CacheLookup NORMAL		// calls imp or objc_msgSend_uncached

	END_ENTRY _objc_msgSendSuper

	// no _objc_msgLookupSuper

	ENTRY _objc_msgSendSuper2
	UNWIND _objc_msgSendSuper2, NoFrame

	ldp	p0, p16, [x0]		// p0 = real receiver, p16 = class
	ldr	p16, [x16, #SUPERCLASS]	// p16 = class->superclass
	CacheLookup NORMAL

	END_ENTRY _objc_msgSendSuper2

	
	ENTRY _objc_msgLookupSuper2
	UNWIND _objc_msgLookupSuper2, NoFrame

	ldp	p0, p16, [x0]		// p0 = real receiver, p16 = class
	ldr	p16, [x16, #SUPERCLASS]	// p16 = class->superclass
	CacheLookup LOOKUP

	END_ENTRY _objc_msgLookupSuper2


.macro MethodTableLookup
	
	// push frame
	SignLR
	stp	fp, lr, [sp, #-16]!
	mov	fp, sp

	// save parameter registers: x0..x8, q0..q7
	sub	sp, sp, #(10*8 + 8*16)
	stp	q0, q1, [sp, #(0*16)]
	stp	q2, q3, [sp, #(2*16)]
	stp	q4, q5, [sp, #(4*16)]
	stp	q6, q7, [sp, #(6*16)]
	stp	x0, x1, [sp, #(8*16+0*8)]
	stp	x2, x3, [sp, #(8*16+2*8)]
	stp	x4, x5, [sp, #(8*16+4*8)]
	stp	x6, x7, [sp, #(8*16+6*8)]
	str	x8,     [sp, #(8*16+8*8)]

	// receiver and selector already in x0 and x1
	mov	x2, x16
	bl	__class_lookupMethodAndLoadCache3

	// IMP in x0
	mov	x17, x0
	
	// restore registers and return
	ldp	q0, q1, [sp, #(0*16)]
	ldp	q2, q3, [sp, #(2*16)]
	ldp	q4, q5, [sp, #(4*16)]
	ldp	q6, q7, [sp, #(6*16)]
	ldp	x0, x1, [sp, #(8*16+0*8)]
	ldp	x2, x3, [sp, #(8*16+2*8)]
	ldp	x4, x5, [sp, #(8*16+4*8)]
	ldp	x6, x7, [sp, #(8*16+6*8)]
	ldr	x8,     [sp, #(8*16+8*8)]

	mov	sp, fp
	ldp	fp, lr, [sp], #16
	AuthenticateLR

.endmacro

	STATIC_ENTRY __objc_msgSend_uncached
	UNWIND __objc_msgSend_uncached, FrameWithNoSaves

	// THIS IS NOT A CALLABLE C FUNCTION
	// Out-of-band p16 is the class to search
	
	MethodTableLookup
	TailCallFunctionPointer x17

	END_ENTRY __objc_msgSend_uncached


	STATIC_ENTRY __objc_msgLookup_uncached
	UNWIND __objc_msgLookup_uncached, FrameWithNoSaves

	// THIS IS NOT A CALLABLE C FUNCTION
	// Out-of-band p16 is the class to search
	
	MethodTableLookup
	ret

	END_ENTRY __objc_msgLookup_uncached


	STATIC_ENTRY _cache_getImp

	GetClassFromIsa_p16 p0
	CacheLookup GETIMP

LGetImpMiss:
	mov	p0, #0
	ret

	END_ENTRY _cache_getImp


/********************************************************************
*
* id _objc_msgForward(id self, SEL _cmd,...);
*
* _objc_msgForward is the externally-callable
*   function returned by things like method_getImplementation().
* _objc_msgForward_impcache is the function pointer actually stored in
*   method caches.
*
********************************************************************/

	STATIC_ENTRY __objc_msgForward_impcache

	// No stret specialization.
	b	__objc_msgForward

	END_ENTRY __objc_msgForward_impcache

	
	ENTRY __objc_msgForward

	adrp	x17, __objc_forward_handler@PAGE
	ldr	p17, [x17, __objc_forward_handler@PAGEOFF]
	TailCallFunctionPointer x17
	
	END_ENTRY __objc_msgForward
	
	
	ENTRY _objc_msgSend_noarg
	b	_objc_msgSend
	END_ENTRY _objc_msgSend_noarg

	ENTRY _objc_msgSend_debug
	b	_objc_msgSend
	END_ENTRY _objc_msgSend_debug

	ENTRY _objc_msgSendSuper2_debug
	b	_objc_msgSendSuper2
	END_ENTRY _objc_msgSendSuper2_debug

	
	ENTRY _method_invoke
	// x1 is method triplet instead of SEL
	add	p16, p1, #METHOD_IMP
	ldr	p17, [x16]
	ldr	p1, [x1, #METHOD_NAME]
	TailCallMethodListImp x17, x16
	END_ENTRY _method_invoke

#endif
