#ifndef ECOL_STATION_NEIGHBOUR_H
#define ECOL_STATION_NEIGHBOUR_H

/*===============复制/opt/tinyos-2.1.2/tos/chips/atm128/atm128hardware.h 中的申明，否则sim编译nx_float出错！！*/

typedef float nx_float __attribute__((nx_base_be(afloat)));

inline float __nesc_ntoh_afloat(const void *COUNT(sizeof(float)) source) @safe() {
  float f;
  memcpy(&f, source, sizeof(float));
  return f;
}

inline float __nesc_hton_afloat(void *COUNT(sizeof(float)) target, float value) @safe() {
  memcpy(target, &value, sizeof(float));
  return value;
}
/*===============END================*/
/*同时修正/opt/tinyos-2.1.2/tos/chips/atm128/timer/Atm128AlarmAsyncP.nc:102: `OCF0' undeclared (first use in this function)
 * 错误，修改该文件：
 * -if ((interrupt_in != 0 && interrupt_in < MINDT) || (tifr & (1 << OCF0))) {
 * +if ((interrupt_in != 0 && interrupt_in < MINDT) || (tifr & (1 << (call TimerCtrl.getInterruptFlag()).bits.ocf0))) {
 * */


enum {
	ORWMSG = 19,					//无线信道号
	MAX_NEIGHBOR_NUM = 20,			//最大邻居数
	PROBE_PERIOD_MILLI = 500,		//探测包发送间隔
	PACKET_PERIOD_MILLI = 32222,	//数据包产生间隔
	PACKET_DUPLICATE_MILLI = 300,	//产生一个数据包后不断发送此包的间隔，直到有节点回复，则回复长发包间隔
	WAKE_PERIOD_MILLI = 1000,		//射频唤醒时长
	WAKE_DELAY_MILLI = 500,			//有包收到之后延迟休眠的时长
	SLEEP_PERIOD_MILLI = 1000,		//睡眠时长
	MESSAGE_PRODUCE_RATIO = 0xA,	//产生数据包的节点比例，0xa表示10，即1/10
};

typedef nx_struct NeighborMsg {
	nx_uint8_t dstid;			//转发单步中的目标接收节点ID，不是最终目的地（最终目的地都是sink ID=1），局部使用
	nx_uint8_t forwarderid;		//转发单步中的转发者（发出者），局部使用
	nx_uint8_t sourceid;		//该数据包的原始来源节点ID号，全局不变
	nx_float forwardingrate;	//转发单步中的转发者（发出者）的转发率，局部使用
	nx_float edc;				//转发单步中的转发者（发出者）的EDC值，局部使用
	nx_uint16_t index;			//包序号
} NeighborMsg;

typedef nx_struct ProbeMsg {
	nx_uint8_t dstid;
	nx_uint8_t sourceid;
	nx_float edc;
} ProbeMsg;

typedef nx_struct ControlMsg {
	nx_uint8_t dstid;
	nx_uint8_t sourceid;
	nx_uint8_t forwardcontrol;	//转发者身份请求，节点收到邻居的节点包后，发送0x1转发者身份请求，发出者判断并回应0x2:同意，0x3:拒绝。
}ControlMsg;

typedef struct NeighborSetNode{
	int nodeID;		//邻居节点属性：节点号
	float edc;		//邻居节点属性：EDC值
	float p;		//邻居节点属性：与本节点链路质量
	bool use;		//邻居节点在本节点中表现的属性：是否在本节点转发表中启用
	int overheadcount;//邻居节点在本节点中表现的属性：串听到邻居节点包的次数（本节点没有被该邻居节点选为转发节点）
}NeighborSet;

#define WEIGHT 0.1F    	  //计算EDC时的weight值，去文中最好的经验值：0.1
#define DATATASK 0x1	  //掩码，是否处于发送数据包的过程中（自己产生的）
#define INITIALIZED 0x2  //掩码，节点是否已经被初始化
#define FORWARDTASK 0x4  //掩码，节点是否处在转发数据包的过程中（别人产生的）
#define MSGSENDER 0x8    //掩码，节点是否具有周期发送数据的资格
#define SLEEPALLOWED 0x10//掩码，是否允许休眠

#endif /* ECOL_STATION_NEIGHBOUR_H */