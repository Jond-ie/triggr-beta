// What the small in-app library (Relay) and SpringBoard say to each other.
// Apps can't run Triggr's actions; they only tell SpringBoard that something
// happened, and only while SpringBoard says a trigger is waiting for it.

#define TGRelayStatusBarTap "com.johndie.triggr/statusbar-tap"
#define TGRelayShake "com.johndie.triggr/shake"
// A Darwin notification state set by SpringBoard: which events are assigned.
#define TGRelayWanted "com.johndie.triggr/relay-wanted"
#define TGRelayWantsStatusBar 1ULL
#define TGRelayWantsShake 2ULL
