/* =========================================================== *
 * 
 * =========================================================== */

#include "Timer.h"

#include "Rout.h"

module RoutC
{
  uses {
    interface Boot;
    interface Timer<TMilli> as PeriodTimer;
    
    interface Random;
    interface ParameterInit<uint16_t> as RandomSeed;
    interface Init as RandomInit;
    
    interface AMSend  as MessageSend;
    interface Packet  as MessagePacket;
    interface Receive as MessageReceive;

    interface Queue<rout_msg_t> as RouterQueue;

    interface SplitControl as MessageControl;
  }
  
}

implementation
{

  /* ==================== GLOBALS ==================== */
  /* Common message buffer */
  message_t packet;
  rout_msg_t *message;

  /* Node to send messages to for routing towards sink */
  int16_t router = -1; 
  bool routerlessreported = FALSE;

  /* If node is looking for a new router */
  bool switchrouter = TRUE;

  /* If the message buffer is in use */
  bool locked = FALSE;

  /* Battery level */
  uint16_t battery = 0;
  
  /* The cluster head of this node */
	uint16_t clusterhead;
  
  /* Count at cluster head */
	uint16_t	count = 1;

  /* ==================== HELPER FUNCTIONS ==================== */

  /* Returns a random number between 0 and n-1 (both inclusive)  */
  uint16_t random(uint16_t n) {
      /* Modulu is a simple but bad way to do it! */
      return (call Random.rand16()) % n;
  }

  bool isSink() {
    return TOS_NODE_ID == SINKNODE;
  }

  int16_t distanceBetweenXY(int16_t ax,int16_t ay,int16_t bx,int16_t by) {
    return (bx - ax) * (bx-ax) + (by - ay) * (by-ay);
  }

  int16_t distanceBetween(int16_t aid,uint16_t bid) {
    int16_t ax = aid % COLUMNS;
    int16_t ay = aid / COLUMNS;
    int16_t bx = bid % COLUMNS;
    int16_t by = bid / COLUMNS;
    return distanceBetweenXY(ax, ay, bx, by);
  }
  
  int16_t distance(int16_t id) {
    return distanceBetween(SINKNODE, id);
  }
  
  char *messageTypeString(int16_t type) {
    switch(type) {
    case TYPE_ANNOUNCEMENT:
      return "ANNOUNCEMENT";
    case TYPE_CONTENT:
      return "CONTENT";
    default:
      return "Unknown";
    }
  }

#define dbgMessageLine(channel,str,mess) dbg(channel,"%s{%d, %s, %d}\n", str, mess->from, messageTypeString(mess->type),mess->seq);
#define dbgMessageLineInt(channel,str1,mess,str2,num) dbg(channel,"%s{%d, %s, %d}%s%d\n", str1, mess->from, messageTypeString(mess->type),mess->seq,str2,num);

  /* ==================== STARTUP ==================== */

  void startnode() {
    battery = BATTERYSTART;
    call PeriodTimer.startPeriodic(PERIOD);
  }

  void stopnode() {
    battery = 0;
    call PeriodTimer.stop();
  }

  event void Boot.booted() {
    call RandomInit.init();
    call MessageControl.start();
    message = (rout_msg_t*)call MessagePacket.getPayload(&packet, sizeof(rout_msg_t));
  }

  event void MessageControl.startDone(error_t err) {
    if (err == SUCCESS) {
      startnode();
    } else {
      call MessageControl.start();
    }
  }

  event void MessageControl.stopDone(error_t err) {
    ;
  }

  /* ==================== BATTERY ==================== */

  /* Returns whether battery has run out */
  uint16_t batteryEmpty() {
    return USEBATTERY && battery == 0;
  }
  
  /**/
  void batteryCheck() {
    if(batteryEmpty()) {
      dbg("Battery","Battery: Node ran out of battery\n");
      stopnode();
    }
  }

  /* Uses the stated level of battery. 
   * Returns wether it was enough or not. 
   * Shuts the node down if battery is emptied
   */
  bool batteryUse(uint16_t use) {
    bool send = (use <= battery);
    if(battery == 0) {
      return FALSE;
    }
    if(send) {
      battery -= use;
      dbg("BatteryUse","BatteryUse: Decreased by %d down to %d\n",use,battery);
    } else {
      battery = 0;
      batteryCheck();
      dbg("BatteryUse","BatteryUse: Ran out when trying to send\n");
    }
    return send;
  }

  uint16_t batteryRequiredForSend(am_addr_t receiver) {
    if(receiver == AM_BROADCAST_ADDR) {
      return MAXDISTANCE;
    } else {
      return distanceBetween(TOS_NODE_ID,receiver);
    }
  }

  /* Uses up battery for sending a message to receiver and returns whether
   * enough battery was left to complete the send. */
  bool batteryUseForSend(am_addr_t receiver) {
    if(USEBATTERY) {
      return batteryUse(batteryRequiredForSend(receiver));
    } else {
      return TRUE;
    }
  }

  /* ==================== ROUTING ==================== */

  void sendMessage(am_addr_t receiver) {
    if(!batteryUseForSend(receiver)) {
      return;
    }
    if (call MessageSend.send(receiver, &packet, sizeof(rout_msg_t)) == SUCCESS) {
      locked = TRUE;
      
      switch(message->type) {
        case TYPE_ANNOUNCEMENT:
          dbgMessageLine("Announcement","Announcement: Sending message ",message);
          break;
        case TYPE_CONTENT:
          dbgMessageLineInt("Content","Content: Sending message ",message," via ",receiver);
          break;
        default:
          dbg("Error","ERROR: Unknown message type");
        }
    } 
    else {
      dbg("Error","ERROR: MessageSend failed");
    }
    batteryCheck();
  }

  void rout() {
    if(call RouterQueue.empty()) {
      dbg("RoutDetail", "Rout: Rout called with empty queue\n");
    } else if(locked) {
      dbg("RoutDetail", "Rout: Message is locked.\n");
    } else if(batteryEmpty()) {
      dbg("RoutDetail", "Rout: Battery is empty.\n");
    } else {
      am_addr_t receiver;
      bool send = FALSE;
      rout_msg_t m = call RouterQueue.head();
      uint8_t type = m.type;
      dbg("RoutDetail", "Rout: Message will be sent.\n");
      switch(type) {
        case TYPE_ANNOUNCEMENT:
          receiver = AM_BROADCAST_ADDR;
          send = TRUE;
          break;
        case TYPE_CONTENT:
          if(router == -1) {
            dbg("RoutDetail", "Rout: No router.\n");
            if(!routerlessreported) {
              dbg("Rout", "Rout: No router to send to\n");
              routerlessreported = TRUE;
            }
          } 
          else {
            receiver = router;
            send = TRUE;
          }
          break;
        default:
          dbg("Error", "ERROR: Unknown message type %d\n", type);
      }
      if(send) {
        *message = call RouterQueue.dequeue();
        sendMessage(receiver);
      }
    }
  }

  void routMessage() {
    if(call RouterQueue.enqueue(*message) != SUCCESS) {
      dbgMessageLine("Rout", "Rout: queue full, message dropped:", message);
    }
    /* Stupid way to put in front of queue */
    if(message->type == TYPE_ANNOUNCEMENT) {
      rout_msg_t m = call RouterQueue.head();
      while(m.type != TYPE_ANNOUNCEMENT) {
        m = call RouterQueue.dequeue();
        call RouterQueue.enqueue(m);
        m = call RouterQueue.head();
      }
    }
    rout();
  }

  /* ==================== ANNOUNCEMENT ==================== */

  /*
   * Here is what is sent in an announcement
   */
  void sendAnnounce() {
    message->from = TOS_NODE_ID;       /* The ID of the node */
    message->type = TYPE_ANNOUNCEMENT;
    message->content = battery;
    message->clhead = clusterhead;
    routMessage();    
  }
  
  /*
   * This it what a node does when it gets an announcement from
   * another node. Here is where the nodttery: Node ran out of batterye chooses which node to use as
   * its router.
   */
  void announceReceive(rout_msg_t *mess) {
    if(switchrouter) {
      /* We need updated router information */
      switchrouter = FALSE;
      router = -1;
			count = 1; //Re-initialize count
    }

    /* Here is the Basic routing algorithm. You will do a better one below. */
    if(BASICROUTER == 0) {
      int16_t myd = distance(TOS_NODE_ID);
      int16_t d   = distance(mess->from);
      if(router == -1 && myd > d) {
        router = mess->from;
      }
    } 

    /* Our implementation of Basic Routing */
    if(BASICROUTER == 1) {
      int16_t myd = distance(TOS_NODE_ID);
      int16_t d   = distance(mess->from);
      int16_t dn  = distanceBetween(TOS_NODE_ID, mess->from);
			//Handle the init phase, when router == -1
      if(router == -1) {
        router = mess->from;
      }
      else {
        int16_t routd = distance(router)+ distanceBetween(TOS_NODE_ID, router);
        if (routd > d+dn && mess->content > d+dn) {
          router = mess->from;
        }
      }
    }

		/* Clustering, part 2 */
    if(BASICROUTER == 2){
			//If this node is a cluster head
      if (clusterhead == TOS_NODE_ID) {
        int16_t myd = distance(TOS_NODE_ID);
        int16_t d   = distance(mess->from);
        int16_t dn  = distanceBetween(TOS_NODE_ID, mess->from);
				//Handle the init phase, when router == -1
        if(router == -1) {
          router = mess->from;
        }
        else {
          int16_t routd = distance(router)+ distanceBetween(TOS_NODE_ID, router);
          if (routd > d+dn && mess->content > d+dn) {
            router = mess->from;
          }
        }
      }
      else{
        int16_t dn  = distanceBetween(TOS_NODE_ID, mess->from);
        int16_t d   = distance(mess->clhead);
				//Handle the init phase, when router == -1
        if(router == -1) {
          router = mess->from;
          clusterhead = mess->from;
        }
        else{
          int16_t routd = distance(router)+ distanceBetween(TOS_NODE_ID, router);          
          if (routd > d+dn && mess->content > d+dn) {
            router = mess->from;
            clusterhead = mess->from;
          }
        }
      }
    }
  }

  /* ==================== CONTENT ==================== */
  
  void sendContent() {
    static uint32_t sequence = 0;
    message->from    = TOS_NODE_ID;       /* The ID of the node */
    message->type    = TYPE_CONTENT;
    message->content = count;							/* The count of the node (for normal node == 1) */
    message->seq     = sequence++;
		message->clhead = clusterhead;				/* The cluster head of this node */
		if (router == -1) {										/* If didn't get any announcement, try sending directly to the sink anyway */
			router = SINKNODE;
		}
    routMessage();
    switchrouter = TRUE; /* Ready for another router round */
  }


  void contentReceive(rout_msg_t *mess) {
		if (BASICROUTER != 2) {		//Not part 2
    	if(call RouterQueue.enqueue(*mess) == SUCCESS) {
      	dbg("RoutDetail", "Rout: Message from %d enqueued\n", mess-> from);
    	} else {
      	dbgMessageLine("Rout", "Rout: queue full, message dropped:", mess);
    	}
    	rout();
		}
		else {	//Part 2
			if (clusterhead == TOS_NODE_ID && !switchrouter) {	//!switchrouter means content is not sent to the sink yet
				count += mess->content;
			}
			else {
    		if(call RouterQueue.enqueue(*mess) == SUCCESS) {
      		dbg("RoutDetail", "Rout: Message from %d enqueued\n", mess-> from);			
    		} else {
      		dbgMessageLine("Rout", "Rout: queue full, message dropped:", mess);
    		}
				rout();
			}
		}
  }

  /*
   * This is what the sink does when it gets content:
   * It just collects it.
   */
  void contentCollect(rout_msg_t *mess) {
    static uint16_t collected = 0;
    if(mess->content > 0) {
      collected += mess->content;
    }
    dbg("Sink", "Sink: Have now collected %d pieces of information\n", collected);
  }

  /* ==================== EVENT CENTRAL ==================== */

  /* This is what drives the rounds
   * We assume that the nodes are synchronized
   */
  event void PeriodTimer.fired() {
    static uint32_t roundcounter = 0;
    if(batteryEmpty()) {
      return;
    }

    dbg("Event","--- EVENT ---: Timer @ round %d\n",roundcounter);
    switch(roundcounter % ROUNDS) {
      case ROUND_ANNOUNCEMENT: /* Announcement time */
				//For part 2, init the cluster head
				if (BASICROUTER == 2) {
					if (isSink() || random(2)) {
						clusterhead = TOS_NODE_ID;
					}
    			else {
      			clusterhead = 0;
    			}
				}
				if (BASICROUTER != 2 || clusterhead == TOS_NODE_ID) {	//Only send announcement in these cases
        	if(isSink()) {
         	 dbg("Round","========== Round %d ==========\n",roundcounter/ROUNDS);
        	}
        	sendAnnounce();
				}
        break;
      case ROUND_CONTENT: /* Message time */
				if (BASICROUTER == 2 && clusterhead != TOS_NODE_ID) {
          sendContent();
				}
        break;
			case ROUND_CONTENT_CL:	/* Aggregate and send (for cluster heads) */
				if (BASICROUTER != 2 || clusterhead == TOS_NODE_ID) {
					if (!isSink()) {
						sendContent();
					}
				}
				break;
      default:
        dbg("Error", "ERROR: Unknown round %d\n", roundcounter);
    }
    roundcounter++;
  }
  
  event message_t* MessageReceive.receive(message_t* bufPtr, void* payload, uint8_t len) {
    rout_msg_t* mess = (rout_msg_t*)payload;
    if(batteryEmpty()) {
      return bufPtr;
    }
    dbgMessageLine("Event","--- EVENT ---: Received ",mess);
    switch(mess->type) {
      case TYPE_ANNOUNCEMENT:
        dbgMessageLine("Announcement","Announcement: Received ",mess);
        announceReceive(mess);
        break;
      case TYPE_CONTENT:
        dbgMessageLine("Content","Content: Received ",mess);
        if(isSink()) {
          contentCollect(mess);
        } else {
          contentReceive(mess);
        }
        break;
      default:
        dbg("Error", "ERROR: Unknown message type %d\n",mess->type);
    }

    /* Because of lack of memory in sensor nodes TinyOS forces us to
     * maintain an equilibrium by givin a buffer back for every
     * message we get. In this case we give it back immediately.  
     * So do not try to save a pointer somewhere to this or the
     * payload */
    return bufPtr;
  }
  
  /* Message has been sent and we are ready to send another one. */
  event void MessageSend.sendDone(message_t* bufPtr, error_t error) {
    dbgMessageLine("Event","--- EVENT ---: sendDone ",message);
    if (&packet == bufPtr) {
      locked = FALSE;
      rout();
    } else {
      dbg("Error", "ERROR: Got sendDone for another message\n");
    }
  }
  

}


