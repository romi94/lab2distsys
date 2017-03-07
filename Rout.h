#ifndef ROUT_H
#define ROUT_H

/* Timer perdiod in milliseconds */
#define PERIOD 500

/* Number of columns in topography */
#define COLUMNS 4

/* Number of different rounds in protocol and the rounds themselves */
#define ROUNDS 3
#define ROUND_ANNOUNCEMENT 0
#define ROUND_CONTENT 1
#define ROUND_CONTENT_CL 2

/* Message type identifiers */
#define TYPE_ANNOUNCEMENT 11
#define TYPE_CONTENT 12

/* Maximum quadratic distance radio can reach */
#define MAXDISTANCE 5

/* Whether the battery model should be used */
#define USEBATTERY   1

/* The starting battery level */
#define BATTERYSTART 100

/* Whether basic routing should be used */
//0 for basic routing
//1 for improvised basic routing
//2 for cluster routing
#define BASICROUTER   2

/* ID of the node that acts as the sink */
#define SINKNODE 0

/* Channel number for the messages */
#define MESSAGE_CHANNEL 7


/* The datastructure for the messages 
 * For additions use the nx_ types.
 * E.g. if you want a int32_t use nx_int32_t
 *
 * Here you can add additional fields that you might need.
 */
typedef nx_struct rout_msg {
  nx_uint8_t  type;
  nx_uint16_t from;
  nx_uint32_t seq;
  nx_uint16_t content;
  nx_uint16_t clhead;
} rout_msg_t;

#endif
