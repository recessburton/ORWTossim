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
	
Logs：
	V0.7 完善转发判断机制，按照ORW，只有非Duplicate的包才转发
	V0.6 从Master分新的Brantch：PureORW，更改了转发授权机制，由原来的根据对方EDC值判断转发资格改为先请求先同意的转发策略，纯粹的机会路由
	V0.5 修正bug #1
	V0.4 采用掩码机制节省空间，简化配置 
	
Known Bugs: 
	#1 V0.4 链路质量p大于1，可达三四十。
		none.

