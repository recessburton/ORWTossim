Author:YTC 
Mail:recessburton@gmail.com
Created Time: 2015.10.16

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>

Description：
	ORW 协议的Tossim仿真模拟实现.
	
Change Log：
	V1.2 改进收到多个ack回复时的判重机制
	V1.1 修正随机时延产生机制，采用时间做随机种子
	V1.0 a.改进日志文件的记录方式
		 b.修正转发数据包成功后，重发次数未置0的bug
	V0.95 加入随机时延机制，在收到包后节点随机延迟一段时间进入休眠流程，防止了在几个节点收到包后，从此进入同步的工作状态的问题。
	V0.9 a.新建版本brantch ORW_withoutQueue, 取消队列机制
	     b.更新数据包交互机制
	     c.加入最大重复发送计数，超过最大次数停止发送或转发
	V0.8 a.数据包加入buffer和删除的标准改为sourceid是否重复（而且index更大），原为forwardid，不妥
	     b.forward过程加入队列机制，使得节点可以同时承担多个不同数据包的转发任务
	V0.7 完善转发判断机制，按照ORW，只有非Duplicate的包才转发
	V0.6 从Master分新的Brantch：PureORW，更改了转发授权机制，由原来的根据对方EDC值判断转发资格改为先请求先同意的转发策略，纯粹的机会路由
	V0.5 修正bug #1
	V0.4 采用掩码机制节省空间，简化配置 

Known Bugs: 
	#1 V0.4 链路质量p大于1，可达三四十。 FIXED.
	#2 V1.1 长时间工作后邻居表中部分节点的EDC变成无穷大。 UNHANDLED.  

