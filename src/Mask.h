#ifndef MASK_H
#define MASK_H

#define DATATASK 0x1	     //掩码，是否处于发送数据包的过程中（自己产生的）
#define INITIALIZED 0x2      //掩码，节点是否已经被初始化
#define FORWARDTASK 0x4      //掩码，节点是否处在转发数据包的过程中（别人产生的）
#define PAYLOADSOURCE 0x8    //掩码，节点是否具有周期发送数据的资格
#define SLEEPALLOWED 0x10    //掩码，是否允许休眠

/*位运算之掩码使用：
 * 打开位： flags = flags | MASK
 * 关闭位： flags = flags & ~MASK
 * 转置位： flags = flags ^ MASK
 * 查看位： (flags&MASK) == MASK
 * */

#define SETFLAG(a, b) ((a) |= (b))
#define UNSETFLAG(a, b) ((a) &= ~(b))
#define TESTFLAG(a, b) ((a) & (b))



#endif /* MASK_H */
