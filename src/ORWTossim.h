#ifndef ORW_TOSSIM_H
#define ORW_TOSSIM_H

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
	DATAPAYLOAD = 11,				//无线信道号，数据包
	CTRLMSG = 12,                   //无线信道号，控制包
	PAYLOAD_PERIOD_MILLI = 360222,	//数据包产生间隔
	PACKET_DUPLICATE_MILLI = 290,	//120产生一个数据包后不断发送此包的间隔，直到有节点回复，则恢复长发包间隔（PAYLOAD_PERIOD_MILLI）
	WAKE_PERIOD_MILLI_BASE = 600,	//射频唤醒时长(随机数基数)600-700，ORW实验固定为650
	SLEEP_PERIOD_MILLI = 2048,		//睡眠时长
	PAYLOAD_PRODUCE_RATIO = 5,	    //产生数据包的节点比例，即5%
};

typedef nx_struct DataPayload {
	nx_uint8_t sourceid;		//该数据包的原始来源节点ID号，全局不变
	nx_uint8_t hops;            //该数据包已经过的累计跳数，初始化为0
	nx_float edc;				//转发单步中的转发者（发出者）的EDC值，局部使用
	nx_uint16_t index;			//包序号
} DataPayload;

typedef struct NeighborSetNode{
	int nodeid;		//邻居节点属性：节点号
	float edc;		//邻居节点属性：EDC值
	float p;		//邻居节点属性：与本节点链路质量
	bool use;		//邻居节点在本节点中表现的属性：是否在本节点转发表中启用
}NeighborSet;

typedef struct overheardcountlistnode{
	int nodeid;
	int overheardcount;
	int forwardcount;
}overheardcountlistnode;

#define WEIGHT 0.1F    	     //计算EDC时的weight值，取文中最好的经验值：0.1
#define MAX_REPLICA_COUNT 10  //最大数据包转发重复计数 10


//空转函数，延迟，用于各种包回复前的随机延迟，防止多个节点同时回复一个包，导致干扰.仿照c库delay()函数实现
	/*uint32_t start,now; \
	int r=randNum;\
	start = call LocalTime.get();\
	do{\
		now=call LocalTime.get();\
	}while(now-start<r);\*/ /*方法一：上述代码仿真环境不可用*/

/*int r=randNum;\
	do{\
		int Num=992;\
		do{\
			Num--;\
		}while(Num);\
	}while(--r);\
 * */ /*方法二：上述方法仿真环境不可用*/

#define RANDOMDELAY(randNum) do { \
	int r = randNum;\
	sim_set_time(sim_time()+(sim_time_t)(r*10000000));\
} while (/*CONSTCOND*/0)   /*方法三：此方法仅可用于仿真环境*/
/*此方法将仿真时间推后了，但此处的仿真时间是每个节点各自的还是仿真环境全局的？
 * 如果是后者，那么，在推迟的一段时间内，所有事件是不是都无法被捕捉？*/
 

#endif /* ORW_TOSSIM_H */




