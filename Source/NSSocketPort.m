/** Implementation of network port object based on TCP sockets
   Copyright (C) 2000 Free Software Foundation, Inc.
   
   Written by:  Richard Frith-Macdonald <richard@brainstorm.co.uk>
   Based on code by:  Andrew Kachites McCallum <mccallum@gnu.ai.mit.edu>
   
   This file is part of the GNUstep Base Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.
   
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.
   
   You should have received a copy of the GNU Library General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111 USA.
   */ 

#include "config.h"
#include "GNUstepBase/preface.h"
#include "Foundation/NSArray.h"
#include "Foundation/NSNotification.h"
#include "Foundation/NSException.h"
#include "Foundation/NSRunLoop.h"
#include "Foundation/NSByteOrder.h"
#include "Foundation/NSData.h"
#include "Foundation/NSDate.h"
#include "Foundation/NSHost.h"
#include "Foundation/NSMapTable.h"
#include "Foundation/NSPortMessage.h"
#include "Foundation/NSPortNameServer.h"
#include "Foundation/NSLock.h"
#include "Foundation/NSHost.h"
#include "Foundation/NSThread.h"
#include "Foundation/NSConnection.h"
#include "Foundation/NSDebug.h"
#include <stdio.h>
#include <stdlib.h>
#ifdef HAVE_UNISTD_H
#include <unistd.h>		/* for gethostname() */
#endif

#ifdef __MINGW__
#define close closesocket
#else
#include <sys/param.h>		/* for MAXHOSTNAMELEN */
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>		/* for inet_ntoa() */
#endif /* !__MINGW__ */
#include <errno.h>
#include <limits.h>
#include <string.h>		/* for strchr() */
#include <ctype.h>		/* for strchr() */
#include <fcntl.h>
#ifdef __MINGW__
#include <winsock2.h>
#include <wininet.h>
#include <process.h>
#include <sys/time.h>
#else
#include <sys/time.h>
#include <sys/resource.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/file.h>
/*
 *	Stuff for setting the sockets into non-blocking mode.
 */
#ifdef	__POSIX_SOURCE
#define NBLK_OPT     O_NONBLOCK
#else
#define NBLK_OPT     FNDELAY
#endif

#include <netinet/in.h>
#include <net/if.h>
#if	!defined(SIOCGIFCONF) || defined(__CYGWIN__)
#include <sys/ioctl.h>
#ifndef	SIOCGIFCONF
#include <sys/sockio.h>
#endif
#endif

#if	defined(__svr4__)
#include <sys/stropts.h>
#endif

#define	SOCKET	int
#define	SOCKET_ERROR	-1
#define	INVALID_SOCKET	-1

#endif /* !__MINGW__ */

static	BOOL	multi_threaded = NO;

/*
 * Largest chunk of data possible in DO
 */
static gsu32	maxDataLength = 10 * 1024 * 1024;

#if 1
#define	M_LOCK(X) {NSDebugMLLog(@"GSTcpHandleLock",@"lock %@ in %@",X,[NSThread currentThread]); [X lock];}
#define	M_UNLOCK(X) {NSDebugMLLog(@"GSTcpHandleLock",@"unlock %@ in %@",X,[NSThread currentThread]); [X unlock];}
#else
#define	M_LOCK(X) {[X lock];}
#define	M_UNLOCK(X) {[X unlock];}
#endif

#define	GS_CONNECTION_MSG	0
#define	NETBLOCK	8192

#ifndef INADDR_NONE
#define	INADDR_NONE	-1
#endif

/*
 * Theory of operation
 *
 * 
 */


/* Private interfaces */

/*
 * The GSPortItemType constant is used to identify the type of data in
 * each packet read.  All data transmitted is in a packet, each packet
 * has an initial packet type and packet length.
 */
typedef	enum {
  GSP_NONE,
  GSP_PORT,		/* Simple port item.			*/
  GSP_DATA,		/* Simple data item.			*/
  GSP_HEAD		/* Port message header + initial data.	*/
} GSPortItemType;

/*
 * The GSPortItemHeader structure defines the header for each item transmitted.
 * Its contents are transmitted in network byte order.
 */
typedef struct {
  gsu32	type;		/* A GSPortItemType as a 4-byte number.		*/
  gsu32	length;		/* The length of the item (excluding header).	*/
} GSPortItemHeader;

/*
 * The GSPortMsgHeader structure is at the start of any item of type GSP_HEAD.
 * Its contents are transmitted in network byte order.
 * Any additional data in the item is an NSData object.
 * NB. additional data counts as part of the same item.
 */
typedef struct {
  gsu32	mId;		/* The ID for the message starting with this.	*/
  gsu32	nItems;		/* Number of items (including this one).	*/
} GSPortMsgHeader;

typedef	struct {
  gsu16 num;		/* TCP port num	*/
  char	addr[0];	/* host address	*/
} GSPortInfo;

/*
 * Here is how data is transmitted over a socket -
 * Initially the process making the connection sends an item of type
 * GSP_PORT to tell the remote end what port is connecting to it.
 * Therafter, all communication is via port messages.  Each port message
 * consists of an item of type GSP_HEAD followed by zero or more items
 * of type GSP_PORT or GSP_DATA.  The number of items in a port message
 * is encoded in the 'nItems' field of the header.
 */

typedef enum {
  GS_H_UNCON = 0,	// Currently idle and unconnected.
  GS_H_TRYCON,		// Trying connection (outgoing).
  GS_H_ACCEPT,		// Making initial connection (incoming).
  GS_H_CONNECTED	// Currently connected.
} GSHandleState;

@interface GSTcpHandle : NSObject <GCFinalization, RunLoopEvents>
{
  SOCKET		desc;		/* File descriptor for I/O.	*/
  unsigned		wItem;		/* Index of item being written.	*/
  NSMutableData		*wData;		/* Data object being written.	*/
  unsigned		wLength;	/* Ammount written so far.	*/
  NSMutableArray	*wMsgs;		/* Message in progress.		*/
  NSMutableData		*rData;		/* Buffer for incoming data	*/
  gsu32			rLength;	/* Amount read so far.		*/
  gsu32			rWant;		/* Amount desired.		*/
  NSMutableArray	*rItems;	/* Message in progress.		*/
  GSPortItemType	rType;		/* Type of data being read.	*/
  gsu32			rId;		/* Id of incoming message.	*/
  unsigned		nItems;		/* Number of items to be read.	*/
  GSHandleState		state;		/* State of the handle.		*/
  unsigned int		addrNum;	/* Address number within host.	*/
@public
  NSRecursiveLock	*myLock;	/* Lock for this handle.	*/
  BOOL			caller;		/* Did we connect to other end?	*/
  BOOL			valid;
  NSSocketPort		*recvPort;
  NSSocketPort		*sendPort;
  struct sockaddr_in	sockAddr;	/* Far end of connection.	*/
  NSString		*defaultAddress;
}

+ (GSTcpHandle*) handleWithDescriptor: (SOCKET)d;
- (BOOL) connectToPort: (NSSocketPort*)aPort beforeDate: (NSDate*)when;
- (int) descriptor;
- (void) invalidate;
- (BOOL) isValid;
- (void) receivedEvent: (void*)data
                  type: (RunLoopEventType)type
		 extra: (void*)extra
	       forMode: (NSString*)mode;
- (NSSocketPort*) recvPort;
- (BOOL) sendMessage: (NSArray*)components beforeDate: (NSDate*)when;
- (NSSocketPort*) sendPort;
- (void) setState: (GSHandleState)s;
- (GSHandleState) state;
- (NSDate*) timedOutEvent: (void*)data
		     type: (RunLoopEventType)type
		  forMode: (NSString*)mode;
@end


/*
 * Utility functions for encoding and decoding ports.
 */
static NSSocketPort*
decodePort(NSData *data, NSString *defaultAddress)
{
  GSPortItemHeader	*pih;
  GSPortInfo		*pi;
  NSString		*addr;
  gsu16			pnum;
  gsu32			length;
  NSHost		*host;
  unichar		c;
  
  pih = (GSPortItemHeader*)[data bytes];
  NSCAssert(GSSwapBigI32ToHost(pih->type) == GSP_PORT,
    NSInternalInconsistencyException);
  length = GSSwapBigI32ToHost(pih->length);
  pi = (GSPortInfo*)&pih[1];
  pnum = GSSwapBigI16ToHost(pi->num);
  if (strncmp(pi->addr, "VER", 3) == 0)
    {
      NSLog(@"Remote version of GNUstep at %s:%d is more recent than this one",
	pi->addr, pnum); 
      return nil;
    }
  addr = [NSString stringWithCString: pi->addr];

  NSDebugFLLog(@"NSPort", @"Decoded port as '%@:%d'", addr, pnum);

  /*
   * Special case - the encoded port was on the host from which the
   * message was sent.
   */
  if ([addr length] == 0)
    {
      addr = defaultAddress;
    }
  c = [addr characterAtIndex: 0];
  if (c >= '0' && c <= '9')
    {
      host = [NSHost hostWithAddress: addr];
    }
  else
    {
      host = [NSHost hostWithName: addr];
    }

  return [NSSocketPort portWithNumber: pnum
			       onHost: host
			 forceAddress: nil
			     listener: NO];
}

static NSData*
newDataWithEncodedPort(NSSocketPort *port)
{
  GSPortItemHeader	*pih;
  GSPortInfo		*pi;
  NSMutableData		*data;
  unsigned		plen;
  NSString		*addr;
  gsu16			pnum;
  
  pnum = [port portNumber];
  addr = [port address];
  if (addr == nil)
    {
      static NSHost	*local = nil;

      /*
       * If the port is not forced to use a specific address ...
       * 1. see if it is on the local host, and if so, encode as "".
       * 2. see if it s a hostname and if so, use the name.
       * 3. pick one of the host addresses.
       * 4. use the localhost address.
       */
      if (local == nil)
	{
	  local = RETAIN([NSHost localHost]);
	}
      if ([[port host] isEqual: local] == YES)
	{
	  addr = @"";
	}
      else if ((addr = [[port host] name]) == nil)
	{
	  addr = [[port host] address];
	  if (addr == nil)
	    {
	      addr = @"127.0.0.1";	/* resign ourselves to this	*/
	    }
	}
    }
  plen = [addr cStringLength] + 3;
  data = [[NSMutableData alloc] initWithLength: sizeof(GSPortItemHeader)+plen];
  pih = (GSPortItemHeader*)[data mutableBytes];
  pih->type = GSSwapHostI32ToBig(GSP_PORT);
  pih->length = GSSwapHostI32ToBig(plen);
  pi = (GSPortInfo*)&pih[1];
  pi->num = GSSwapHostI16ToBig(pnum);
  [addr getCString: pi->addr];

  NSDebugFLLog(@"NSPort", @"Encoded port as '%@:%d'", addr, pnum);

  return data;
}



@implementation	GSTcpHandle

static Class	mutableArrayClass;
static Class	mutableDataClass;
static Class	portMessageClass;
static Class	runLoopClass;

+ (id) allocWithZone: (NSZone*)zone
{
  [NSException raise: NSGenericException
	      format: @"attempt to alloc a GSTcpHandle!"];
  return nil;
}

+ (GSTcpHandle*) handleWithDescriptor: (SOCKET)d
{
  GSTcpHandle	*handle;
#ifdef __MINGW__
  unsigned long dummy;
#else
  int		e;
#endif /* __MINGW__ */

  if (d == INVALID_SOCKET)
    {
      NSLog(@"illegal descriptor (%d) for Tcp Handle", d);
      return nil;
    }
#ifdef __MINGW__
  dummy = 1;
  if (ioctlsocket(d, FIONBIO, &dummy) == SOCKET_ERROR)
    {
      NSLog(@"unable to set non-blocking mode on %d - %s",
	d, GSLastErrorStr(errno));
      return nil;
    }
#else /* !__MINGW__ */
  if ((e = fcntl(d, F_GETFL, 0)) >= 0)
    {
      e |= NBLK_OPT;
      if (fcntl(d, F_SETFL, e) < 0)
	{
	  NSLog(@"unable to set non-blocking mode on %d - %s",
	    d, GSLastErrorStr(errno));
	  return nil;
	}
    }
  else
    {
      NSLog(@"unable to get non-blocking mode on %d - %s",
	d, GSLastErrorStr(errno));
      return nil;
    }
#endif
  handle = (GSTcpHandle*)NSAllocateObject(self, 0, NSDefaultMallocZone());
  handle->desc = d;
  handle->wMsgs = [NSMutableArray new];
  if (multi_threaded == YES)
    {
      handle->myLock = [NSRecursiveLock new];
    }
  handle->valid = YES;
  return AUTORELEASE(handle);
}

+ (void) initialize
{
  if (self == [GSTcpHandle class])
    {
#ifdef __MINGW__
      WORD wVersionRequested;
      WSADATA wsaData;

      wVersionRequested = MAKEWORD(2, 0);
      WSAStartup(wVersionRequested, &wsaData);
#endif
      mutableArrayClass = [NSMutableArray class];
      mutableDataClass = [NSMutableData class];
      portMessageClass = [NSPortMessage class];
      runLoopClass = [NSRunLoop class];
    }
}

- (BOOL) connectToPort: (NSSocketPort*)aPort beforeDate: (NSDate*)when
{
  NSArray		*addrs;
  BOOL			gotAddr = NO;
  NSRunLoop		*l;

  M_LOCK(myLock);
  NSDebugMLLog(@"GSTcpHandle", @"Connecting on 0x%x in thread 0x%x before %@",
    self, GSCurrentThread(), when);
  if (state != GS_H_UNCON)
    {
      BOOL	result;

      if (state == GS_H_CONNECTED)	/* Already connected.	*/
	{
	  NSLog(@"attempting connect on connected handle");
	  result = YES;
	}
      else if (state == GS_H_ACCEPT)	/* Impossible.	*/
	{
	  NSLog(@"attempting connect with accepting handle");
	  result = NO;
	}
      else				/* Already connecting.	*/
	{
	  NSLog(@"attempting connect while connecting");
	  result = NO;
	}
      M_UNLOCK(myLock);
      return result;
    }

  if (recvPort == nil || aPort == nil)
    {
      NSLog(@"attempting connect with port(s) unset");
      M_UNLOCK(myLock);
      return NO;	/* impossible.		*/
    }

  /*
   * Get an IP address to try to connect to.
   * If the port has a 'forced' address, just use that. Otherwise we try
   * each of the addresses for the host in turn.
   */
  if ([aPort address] != nil)
    {
      addrs = [NSArray arrayWithObject: [aPort address]];
    }
  else
    {
      addrs = [[aPort host] addresses];
    }
  while (gotAddr == NO)
    {
      const char	*addr;

      if (addrNum >= [addrs count])
	{
	  NSLog(@"run out of addresses to try (tried %d) for port %@",
	    addrNum, aPort);
	  M_UNLOCK(myLock);
	  return NO;
	}
      addr = [[addrs objectAtIndex: addrNum++] cString];

      memset(&sockAddr, '\0', sizeof(sockAddr));
      sockAddr.sin_family = AF_INET;
#ifndef HAVE_INET_ATON
      sockAddr.sin_addr.s_addr = inet_addr(addr);
      if (sockAddr.sin_addr.s_addr == INADDR_NONE)
#else
      if (inet_aton(addr, &sockAddr.sin_addr) == 0)
#endif
	{
	  NSLog(@"bad ip address - '%s'", addr);
	}
      else
	{
	  gotAddr = YES;
	  NSDebugMLLog(@"GSTcpHandle", @"Connecting to %s:%d using desc %d",
	    addr, [aPort portNumber], desc);
	}
    }
  sockAddr.sin_port = GSSwapHostI16ToBig([aPort portNumber]);

  if (connect(desc, (struct sockaddr*)&sockAddr, sizeof(sockAddr))
    == SOCKET_ERROR)
    {
#ifdef __MINGW__
      if (WSAGetLastError() != WSAEWOULDBLOCK)
#else
      if (errno != EINPROGRESS)
#endif
	{
	  NSLog(@"unable to make connection to %s:%d - %s",
	    inet_ntoa(sockAddr.sin_addr),
	    GSSwapBigI16ToHost(sockAddr.sin_port), GSLastErrorStr(errno));
	  if (addrNum < [addrs count])
	    {
	      BOOL	result;

	      result = [self connectToPort: aPort beforeDate: when];
	      M_UNLOCK(myLock);
	      return result;
	    }
	  else
	    {
	      M_UNLOCK(myLock);
	      return NO;	/* Tried all addresses	*/
	    }
	}
    }

  state = GS_H_TRYCON;
  l = [NSRunLoop currentRunLoop];
  [l addEvent: (void*)(gsaddr)desc
	 type: ET_WDESC
      watcher: self
      forMode: NSConnectionReplyMode];
  [l addEvent: (void*)(gsaddr)desc
	 type: ET_EDESC
      watcher: self
      forMode: NSConnectionReplyMode];

  while (valid == YES && state == GS_H_TRYCON
    && [when timeIntervalSinceNow] > 0)
    {
      M_UNLOCK(myLock);
      [l runMode: NSConnectionReplyMode beforeDate: when];
      M_LOCK(myLock);
    }

  [l removeEvent: (void*)(gsaddr)desc
	    type: ET_WDESC
	 forMode: NSConnectionReplyMode
	     all: NO];
  [l removeEvent: (void*)(gsaddr)desc
	    type: ET_EDESC
	 forMode: NSConnectionReplyMode
	     all: NO];

  if (state == GS_H_TRYCON)
    {
      state = GS_H_UNCON;
      addrNum = 0;
      M_UNLOCK(myLock);
      return NO;	/* Timed out 	*/
    }
  else if (state == GS_H_UNCON)
    {
      if (addrNum < [addrs count] && [when timeIntervalSinceNow] > 0)
	{
	  BOOL	result;

	  /*
	   * The connection attempt failed, but there are still IP addresses
	   * that we haven't tried.
	   */
	  result = [self connectToPort: aPort beforeDate: when];
	  M_UNLOCK(myLock);
	  return result;
	}
      addrNum = 0;
      state = GS_H_UNCON;
      M_UNLOCK(myLock);
      return NO;	/* connection failed	*/
    }
  else
    {
      addrNum = 0;
      caller = YES;
      [aPort addHandle: self forSend: YES];
      M_UNLOCK(myLock);
      return YES;
    }
}

- (void) dealloc
{
  [self gcFinalize];
  DESTROY(defaultAddress);
  DESTROY(rData);
  DESTROY(rItems);
  DESTROY(wMsgs);
  DESTROY(myLock);
  [super dealloc];
}

- (NSString*) description
{
  return [NSString stringWithFormat: @"Handle (%d) to %s:%d",
    desc, inet_ntoa(sockAddr.sin_addr), ntohs(sockAddr.sin_port)];
}

- (SOCKET) descriptor
{
  return desc;
}

- (void) gcFinalize
{
  [self invalidate];
  (void)close(desc);
  desc = -1;
}

- (void) invalidate
{
  if (valid == YES)
    {
      M_LOCK(myLock);
      if (valid == YES)
	{ 
	  NSRunLoop	*l;

	  valid = NO;
	  l = [runLoopClass currentRunLoop];
	  [l removeEvent: (void*)(gsaddr)desc
		    type: ET_RDESC
		 forMode: nil
		     all: YES];
	  [l removeEvent: (void*)(gsaddr)desc
		    type: ET_WDESC
		 forMode: nil
		     all: YES];
	  [l removeEvent: (void*)(gsaddr)desc
		    type: ET_EDESC
		 forMode: nil
		     all: YES];
	  NSDebugMLLog(@"GSTcpHandle", @"invalidated 0x%x in thread 0x%x",
	    self, GSCurrentThread());
	  [[self recvPort] removeHandle: self];
	  [[self sendPort] removeHandle: self];
	}
      M_UNLOCK(myLock);
    }
}

- (BOOL) isValid
{
  return valid;
}

- (NSSocketPort*) recvPort
{
  if (recvPort == nil)
    return nil;
  else
    return GS_GC_UNHIDE(recvPort);
}

- (void) receivedEvent: (void*)data
                  type: (RunLoopEventType)type
		 extra: (void*)extra
	       forMode: (NSString*)mode
{
  NSDebugMLLog(@"GSTcpHandle", @"received %s event on 0x%x in thread 0x%x",
    type == ET_RPORT ? "read" : "write", self, GSCurrentThread());
  /*
   * If we have been invalidated (desc < 0) then we should ignore this
   * event and remove ourself from the runloop.
   */
  if (desc == INVALID_SOCKET)
    {
      NSRunLoop	*l = [runLoopClass currentRunLoop];

      [l removeEvent: data
		type: ET_WDESC
	     forMode: mode
		 all: YES];
      [l removeEvent: data
		type: ET_EDESC
	     forMode: mode
		 all: YES];
      return;
    }

  M_LOCK(myLock);

  if (type == ET_RPORT)
    {
      unsigned	want;
      void	*bytes;
      int	res;

      /*
       * Make sure we have a buffer big enough to hold all the data we are
       * expecting, or NETBLOCK bytes, whichever is greater.
       */
      if (rData == nil)
	{
	  rData = [[mutableDataClass alloc] initWithLength: NETBLOCK];
	  rWant = sizeof(GSPortItemHeader);
	  rLength = 0;
	  want = NETBLOCK;
	}
      else
	{
	  want = [rData length];
	  if (want < rWant)
	    {
	      want = rWant;
	      [rData setLength: want];
	    }
	  if (want < NETBLOCK)
	    {
	      want = NETBLOCK;
	      [rData setLength: want];
	    }
	}

      /*
       * Now try to fill the buffer with data.
       */
      bytes = [rData mutableBytes];
      res = recv(desc, bytes + rLength, want - rLength, 0);
      if (res <= 0)
	{
	  if (res == 0)
	    {
	      NSDebugMLLog(@"GSTcpHandle", @"read eof on 0x%x in thread 0x%x",
		self, GSCurrentThread());
	      M_UNLOCK(myLock);
	      [self invalidate];
	      return;
	    }
	  else if (errno != EINTR && errno != EAGAIN)
	    {
	      NSDebugMLLog(@"GSTcpHandle",
		@"read failed - %s on 0x%x in thread 0x%x",
		GSLastErrorStr(errno), self, GSCurrentThread());
	      M_UNLOCK(myLock);
	      [self invalidate];
	      return;
	    }
	  res = 0;	/* Interrupted - continue	*/
	}
      NSDebugMLLog(@"GSTcpHandle", @"read %d bytes on 0x%x in thread 0x%x",
	res, self, GSCurrentThread());
      rLength += res;

      while (valid == YES && rLength >= rWant)
	{
	  BOOL	shouldDispatch = NO;

	  switch (rType)
	    {
	      case GSP_NONE:
		{
		  GSPortItemHeader	*h;
		  unsigned		l;

		  /*
		   * We have read an item header - set up to read the
		   * remainder of the item.
		   */
		  h = (GSPortItemHeader*)bytes;
		  rType = GSSwapBigI32ToHost(h->type);
		  l = GSSwapBigI32ToHost(h->length);
		  if (rType == GSP_PORT)
		    {
		      if (l > 128)
			{
			  NSLog(@"%@ - unreasonable length (%u) for port",
			    self, l);
			  M_UNLOCK(myLock);
			  [self invalidate];
			  return;
			}
		      /*
		       * For a port, we leave the item header in the data
		       * so that our decode function can check length info.
		       */
		      rWant += l;
		    }
		  else if (rType == GSP_DATA)
		    {
		      if (l == 0)
			{
			  NSData	*d;

			  /*
			   * For a zero-length data chunk, we create an empty
			   * data object and add it to the current message.
			   */
			  rType = GSP_NONE;	/* ready for a new item	*/
			  rLength -= rWant;
			  if (rLength > 0)
			    {
			      memcpy(bytes, bytes + rWant, rLength);
			    }
			  rWant = sizeof(GSPortItemHeader);
			  d = [mutableDataClass new];
			  [rItems addObject: d];
			  RELEASE(d);
			  if (nItems == [rItems count])
			    {
			      shouldDispatch = YES;
			    }
			}
		      else
			{
			  if (l > maxDataLength)
			    {
			      NSLog(@"%@ - unreasonable length (%u) for data",
				self, l);
			      M_UNLOCK(myLock);
			      [self invalidate];
			      return;
			    }
			  /*
			   * If not a port or zero length data,
			   * we discard the data read so far and fill the
			   * data object with the data item from the msg.
			   */
			  rLength -= rWant;
			  if (rLength > 0)
			    {
			      memcpy(bytes, bytes + rWant, rLength);
			    }
			  rWant = l;
			}
		    }
		  else if (rType == GSP_HEAD)
		    {
		      if (l > maxDataLength)
			{
			  NSLog(@"%@ - unreasonable length (%u) for data",
			    self, l);
			  M_UNLOCK(myLock);
			  [self invalidate];
			  return;
			}
		      /*
		       * If not a port or zero length data,
		       * we discard the data read so far and fill the
		       * data object with the data item from the msg.
		       */
		      rLength -= rWant;
		      if (rLength > 0)
			{
			  memcpy(bytes, bytes + rWant, rLength);
			}
		      rWant = l;
		    }
		  else
		    {
		      NSLog(@"%@ - bad data received on port handle", self);
		      M_UNLOCK(myLock);
		      [self invalidate];
		      return;
		    }
		}
		break;

	      case GSP_HEAD:
		{
		  GSPortMsgHeader	*h;

		  rType = GSP_NONE;	/* ready for a new item	*/
		  /*
		   * We have read a message header - set up to read the
		   * remainder of the message.
		   */
		  h = (GSPortMsgHeader*)bytes;
		  rId = GSSwapBigI32ToHost(h->mId);
		  nItems = GSSwapBigI32ToHost(h->nItems);
		  NSAssert(nItems >0, NSInternalInconsistencyException);
		  rItems
		    = [mutableArrayClass allocWithZone: NSDefaultMallocZone()];
		  rItems = [rItems initWithCapacity: nItems];
		  if (rWant > sizeof(GSPortMsgHeader))
		    {
		      NSData	*d;

		      /*
		       * The first data item of the message was included in
		       * the header - so add it to the rItems array.
		       */
		      rWant -= sizeof(GSPortMsgHeader);
		      d = [mutableDataClass alloc];
		      d = [d initWithBytes: bytes + sizeof(GSPortMsgHeader)
				    length: rWant];
		      [rItems addObject: d];
		      RELEASE(d);
		      rWant += sizeof(GSPortMsgHeader);
		      rLength -= rWant;
		      if (rLength > 0)
			{
			  memcpy(bytes, bytes + rWant, rLength);
			}
		      rWant = sizeof(GSPortItemHeader);
		      if (nItems == 1)
			{
			  shouldDispatch = YES;
			}
		    }
		  else
		    {
		      /*
		       * want to read another item
		       */
		      rLength -= rWant;
		      if (rLength > 0)
			{
			  memcpy(bytes, bytes + rWant, rLength);
			}
		      rWant = sizeof(GSPortItemHeader);
		    }
		}
		break;

	      case GSP_DATA:
		{
		  NSData	*d;

		  rType = GSP_NONE;	/* ready for a new item	*/
		  d = [mutableDataClass allocWithZone: NSDefaultMallocZone()];
		  d = [d initWithBytes: bytes length: rWant];
		  [rItems addObject: d];
		  RELEASE(d);
		  rLength -= rWant;
		  if (rLength > 0)
		    {
		      memcpy(bytes, bytes + rWant, rLength);
		    }
		  rWant = sizeof(GSPortItemHeader);
		  if (nItems == [rItems count])
		    {
		      shouldDispatch = YES;
		    }
		}
		break;

	      case GSP_PORT:
		{
		  NSSocketPort	*p;

		  rType = GSP_NONE;	/* ready for a new item	*/
		  p = decodePort(rData, defaultAddress);
		  if (p == nil)
		    {
		      NSLog(@"%@ - unable to decode remote port", self);
		      M_UNLOCK(myLock);
		      [self invalidate];
		      return;
		    }
		  /*
		   * Set up to read another item header.
		   */
		  rLength -= rWant;
		  if (rLength > 0)
		    {
		      memcpy(bytes, bytes + rWant, rLength);
		    }
		  rWant = sizeof(GSPortItemHeader);

		  if (state == GS_H_ACCEPT)
		    {
		      /*
		       * This is the initial port information on a new
		       * connection - set up port relationships.
		       */
		      state = GS_H_CONNECTED;
		      [p addHandle: self forSend: YES];
		    }
		  else
		    {
		      /*
		       * This is a port within a port message - add
		       * it to the message components.
		       */
		      [rItems addObject: p];
		      if (nItems == [rItems count])
			{
			  shouldDispatch = YES;
			}
		    }
		}
		break;
	    }

	  if (shouldDispatch == YES)
	    {
	      NSPortMessage	*pm;
	      NSSocketPort		*rp = [self recvPort];

	      pm = [portMessageClass allocWithZone: NSDefaultMallocZone()];
	      pm = [pm initWithSendPort: [self sendPort]
			    receivePort: rp
			     components: rItems];
	      [pm setMsgid: rId];
	      rId = 0;
	      DESTROY(rItems);
	      NSDebugMLLog(@"GSTcpHandle",
		@"got message %@ on 0x%x in thread 0x%x",
		pm, self, GSCurrentThread());
	      RETAIN(rp);
	      M_UNLOCK(myLock);
	      NS_DURING
		{
		  [rp handlePortMessage: pm];
		}
	      NS_HANDLER
		{
		  M_LOCK(myLock);
		  RELEASE(pm);
		  RELEASE(rp);
		  [localException raise];
		}
	      NS_ENDHANDLER
	      M_LOCK(myLock);
	      RELEASE(pm);
	      RELEASE(rp);
	      bytes = [rData mutableBytes];
	    }
	}
    }
  else
    {
      if (state == GS_H_TRYCON)	/* Connection attempt.	*/
	{
	  int	res = 0;
	  int	len = sizeof(res);

	  if (getsockopt(desc, SOL_SOCKET, SO_ERROR, (char*)&res, &len) == 0
	    && res != 0)
	    {
	      state = GS_H_UNCON;
	      NSLog(@"connect attempt failed - %s", GSLastErrorStr(res));
	    }
	  else
	    {
	      NSData	*d = newDataWithEncodedPort([self recvPort]);

	      len = send(desc, [d bytes], [d length], 0);
	      if (len == (int)[d length])
		{
		  RELEASE(defaultAddress);
		  defaultAddress = RETAIN([NSString stringWithCString:
		    inet_ntoa(sockAddr.sin_addr)]);
		  NSDebugMLLog(@"GSTcpHandle",
		    @"wrote %d bytes on 0x%x in thread 0x%x",
		    len, self, GSCurrentThread());
		  state = GS_H_CONNECTED;
		}
	      else
		{
		  state = GS_H_UNCON;
		  NSLog(@"connect write attempt failed - %s",
		    GSLastErrorStr(errno));
		}
	      RELEASE(d);
	    }
	}
      else
	{
	  int		res;
	  unsigned	l;
	  const void	*b;

	  if (wData == nil)
	    {
	      if ([wMsgs count] > 0)
		{
		  NSArray	*components = [wMsgs objectAtIndex: 0];

		  wData = [components objectAtIndex: wItem++];
		  wLength = 0;
		}
	      else
		{
		  // NSLog(@"No messages to write on 0x%x.", self);
		  M_UNLOCK(myLock);
		  return;
		}
	    }
	  b = [wData bytes];
	  l = [wData length];
	  res = send(desc, b + wLength,  l - wLength, 0);
	  if (res < 0)
	    {
	      if (errno != EINTR && errno != EAGAIN)
		{
		  NSLog(@"write attempt failed - %s", GSLastErrorStr(errno));
		  M_UNLOCK(myLock);
		  [self invalidate];
		  return;
		}
	    }
	  else
	    {
	      NSDebugMLLog(@"GSTcpHandle",
		@"wrote %d bytes on 0x%x in thread 0x%x",
		res, self, GSCurrentThread());
	      wLength += res;
	      if (wLength == l)
		{
		  NSArray	*components;

		  /*
		   * We have completed a data item so see what is
		   * left of the message components.
		   */
		  components = [wMsgs objectAtIndex: 0];
		  wLength = 0;
		  if ([components count] > wItem)
		    {
		      /*
		       * More to write - get next item.
		       */
		      wData = [components objectAtIndex: wItem++];
		    }
		  else
		    {
		      /*
		       * message completed - remove from list.
		       */
		      NSDebugMLLog(@"GSTcpHandle",
			@"completed 0x%x on 0x%x in thread 0x%x",
			components, self, GSCurrentThread());
		      wData = nil;
		      wItem = 0;
		      [wMsgs removeObjectAtIndex: 0];
		    }
		}
	    }
	}
    }

  M_UNLOCK(myLock);
}

- (BOOL) sendMessage: (NSArray*)components beforeDate: (NSDate*)when
{
  NSRunLoop	*l;
  BOOL		sent = NO;

  NSAssert([components count] > 0, NSInternalInconsistencyException);
  NSDebugMLLog(@"GSTcpHandle",
    @"Sending message 0x%x %@ on 0x%x(%d) in thread 0x%x before %@",
    components, components, self, desc, GSCurrentThread(), when);
  M_LOCK(myLock);
  [wMsgs addObject: components];

  l = [runLoopClass currentRunLoop];

  RETAIN(self);

  [l addEvent: (void*)(gsaddr)desc
	 type: ET_WDESC
      watcher: self
      forMode: NSConnectionReplyMode];
  [l addEvent: (void*)(gsaddr)desc
	 type: ET_EDESC
      watcher: self
      forMode: NSConnectionReplyMode];

  while (valid == YES
    && [wMsgs indexOfObjectIdenticalTo: components] != NSNotFound
    && [when timeIntervalSinceNow] > 0)
    {
      M_UNLOCK(myLock);
      [l runMode: NSConnectionReplyMode beforeDate: when];
      M_LOCK(myLock);
    }

  [l removeEvent: (void*)(gsaddr)desc
	    type: ET_WDESC
	 forMode: NSConnectionReplyMode
	     all: NO];
  [l removeEvent: (void*)(gsaddr)desc
	    type: ET_EDESC
	 forMode: NSConnectionReplyMode
	     all: NO];

  if ([wMsgs indexOfObjectIdenticalTo: components] == NSNotFound)
    {
      sent = YES;
    }
  M_UNLOCK(myLock);
  RELEASE(self);
  NSDebugMLLog(@"GSTcpHandle",
    @"Message send 0x%x on 0x%x in thread 0x%x status %d",
    components, self, GSCurrentThread(), sent);
  return sent;
}

- (NSSocketPort*) sendPort
{
  if (sendPort == nil)
    return nil;
  else if (caller == YES)
    return GS_GC_UNHIDE(sendPort);	// We called, so port is not retained.
  else
    return sendPort;			// Retained port.
}

- (void) setState: (GSHandleState)s
{
  state = s;
}

- (GSHandleState) state
{
  return state;
}

- (NSDate*) timedOutEvent: (void*)data
		     type: (RunLoopEventType)type
		  forMode: (NSString*)mode
{
  return nil;
}

@end



@interface NSSocketPort (RunLoop) <RunLoopEvents>
- (void) receivedEvent: (void*)data
                  type: (RunLoopEventType)type
		 extra: (void*)extra
	       forMode: (NSString*)mode;
- (NSDate*) timedOutEvent: (void*)data
		     type: (RunLoopEventType)type
		  forMode: (NSString*)mode;
@end

@implementation	NSSocketPort

static NSRecursiveLock	*tcpPortLock = nil;
static NSMapTable	*tcpPortMap = 0;
static Class		tcpPortClass;

/*
 *	When the system becomes multithreaded, we set a flag to say so and
 *	make sure that port and handle locking is enabled.
 */
+ (void) _becomeThreaded: (NSNotification*)notification
{
  if (multi_threaded == NO)
    {
      NSMapEnumerator	pEnum;
      NSMapTable	*m;
      void		*dummy;

      multi_threaded = YES;
      if (tcpPortLock == nil)
	{
	  tcpPortLock = [NSRecursiveLock new];
	}
      pEnum = NSEnumerateMapTable(tcpPortMap);
      while (NSNextMapEnumeratorPair(&pEnum, &dummy, (void**)&m))
	{
	  NSMapEnumerator	mEnum;
	  NSSocketPort		*p;

	  mEnum = NSEnumerateMapTable(m);
	  while (NSNextMapEnumeratorPair(&mEnum, &dummy, (void**)&p))
	    {
	      if ([p isValid] == YES)
		{
		  NSMapEnumerator	hEnum;
		  GSTcpHandle		*h;

		  if (p->myLock == nil)
		    {
		      p->myLock = [NSRecursiveLock new];
		    }
		  hEnum = NSEnumerateMapTable(p->handles);
		  while (NSNextMapEnumeratorPair(&hEnum, &dummy, (void**)&h))
		    {
		      if ([h isValid] == YES && h->myLock == nil)
			{
			  h->myLock = [NSRecursiveLock new];
			}
		    }
		  NSEndMapTableEnumeration(&hEnum);
		}
	    }
	  NSEndMapTableEnumeration(&mEnum);
	}
      NSEndMapTableEnumeration(&pEnum);
    }
  [[NSNotificationCenter defaultCenter]
    removeObserver: self
	      name: NSWillBecomeMultiThreadedNotification
	    object: nil];
}

#if NEED_WORD_ALIGNMENT
static unsigned	wordAlign;
#endif

+ (void) initialize
{
  if (self == [NSSocketPort class])
    {
#if NEED_WORD_ALIGNMENT
      wordAlign = objc_alignof_type(@encode(gsu32));
#endif
      tcpPortClass = self;
      tcpPortMap = NSCreateMapTable(NSIntMapKeyCallBacks,
	NSNonOwnedPointerMapValueCallBacks, 0);

      if ([NSThread isMultiThreaded])
	{
	  [self _becomeThreaded: nil];
	}
      else
	{
	  [[NSNotificationCenter defaultCenter]
	    addObserver: self
	       selector: @selector(_becomeThreaded:)
		   name: NSWillBecomeMultiThreadedNotification
		 object: nil];
	}
    }
}

+ (id) new
{
  return RETAIN([self portWithNumber: 0
			      onHost: nil
			forceAddress: nil
			    listener: YES]);
}

/*
 * Look up an existing NSSocketPort given a host and number
 */
+ (NSSocketPort*) existingPortWithNumber: (gsu16)number
			       onHost: (NSHost*)aHost
{
  NSSocketPort	*port = nil;
  NSMapTable	*thePorts;

  M_LOCK(tcpPortLock);

  /*
   *	Get the map table of ports with the specified number.
   */
  thePorts = (NSMapTable*)NSMapGet(tcpPortMap, (void*)(gsaddr)number);
  if (thePorts != 0)
    {
      port = (NSSocketPort*)NSMapGet(thePorts, (void*)aHost);
      IF_NO_GC(AUTORELEASE(RETAIN(port)));
    }
  M_UNLOCK(tcpPortLock);
  return port;
}

/*
 * This is the preferred initialisation method for NSSocketPort
 *
 * 'number' should be a TCP/IP port number or may be zero for a port on
 * the local host.
 * 'aHost' should be the host for the port or may be nil for the local
 * host.
 * 'addr' is the IP address that MUST be used for this port - if it is nil
 * then, for the local host, the port uses ALL IP addresses, and for a
 * remote host, the port will use the first address that works.
 */
+ (NSSocketPort*) portWithNumber: (gsu16)number
			  onHost: (NSHost*)aHost
		    forceAddress: (NSString*)addr
			listener: (BOOL)shouldListen
{
  unsigned		i;
  NSSocketPort		*port = nil;
  NSHost		*thisHost = [NSHost localHost];
  NSMapTable		*thePorts;

  if (thisHost == nil)
    {
      NSLog(@"attempt to create port on host without networking set up!");
      return nil;
    }
  if (aHost == nil)
    {
      aHost = thisHost;
    }
  if (addr != nil && [[aHost addresses] containsObject: addr] == NO)
    {
      NSLog(@"attempt to use address '%@' on host without that address", addr);
      return nil;
    }
  if (number == 0 && [thisHost isEqual: aHost] == NO)
    {
      NSLog(@"attempt to get port zero on remote host");
      return nil;
    }

  M_LOCK(tcpPortLock);

  /*
   * First try to find a pre-existing port.
   */
  thePorts = (NSMapTable*)NSMapGet(tcpPortMap, (void*)(gsaddr)number);
  if (thePorts != 0)
    {
      port = (NSSocketPort*)NSMapGet(thePorts, (void*)aHost);
    }

  if (port == nil)
    {
      port = (NSSocketPort*)NSAllocateObject(self, 0, NSDefaultMallocZone());
      port->listener = -1;
      port->host = RETAIN(aHost);
      port->address = [addr copy];
      port->handles = NSCreateMapTable(NSIntMapKeyCallBacks,
	NSObjectMapValueCallBacks, 0);
      if (multi_threaded == YES)
	{
	  port->myLock = [NSRecursiveLock new];
	}
      port->_is_valid = YES;

      if (shouldListen == YES && [thisHost isEqual: aHost])
	{
#ifndef	BROKEN_SO_REUSEADDR
	  int	reuse = 1;	/* Should we re-use ports?	*/
#endif
	  SOCKET desc;
	  BOOL	addrOk = YES;
	  struct sockaddr_in	sockaddr;

	  /*
	   * Creating a new port on the local host - so we must create a
	   * listener socket to accept incoming connections.
	   */
	  memset(&sockaddr, '\0', sizeof(sockaddr));
	  sockaddr.sin_family = AF_INET;
	  if (addr == nil)
	    {
	      sockaddr.sin_addr.s_addr = GSSwapHostI32ToBig(INADDR_ANY);
	    }
	  else
	    {
#ifndef HAVE_INET_ATON
	      sockaddr.sin_addr.s_addr = inet_addr([addr cString]);
	      if (sockaddr.sin_addr.s_addr == INADDR_NONE)
#else
	      if (inet_aton([addr cString], &sockaddr.sin_addr) == 0)
#endif
		{
		  addrOk = NO;
		}
	    }
	  sockaddr.sin_port = GSSwapHostI16ToBig(number);

	  /*
           * Need size of buffer for getsockbyname() later.
	   */
	  i = sizeof(sockaddr);

	  if (addrOk == NO)
	    {
	      NSLog(@"Bad address (%@) specified for listening port", addr);
	      DESTROY(port);
	    }
	  else if ((desc = socket(AF_INET, SOCK_STREAM, PF_UNSPEC))
	    == INVALID_SOCKET)
	    {
	      NSLog(@"unable to create socket - %s", GSLastErrorStr(errno));
	      DESTROY(port);
	    }
#ifndef	BROKEN_SO_REUSEADDR
	  /*
	   * Under decent systems, SO_REUSEADDR means that the port can be
	   * reused immediately that this porcess exits.  Under some it means
	   * that multiple processes can serve the same port simultaneously.
	   * We don't want that broken behavior!
	   */
	  else if (setsockopt(desc, SOL_SOCKET, SO_REUSEADDR, (char*)&reuse,
	    sizeof(reuse)) < 0)
	    {
	      (void) close(desc);
              NSLog(@"unable to set reuse on socket - %s",
		GSLastErrorStr(errno));
              DESTROY(port);
	    }
#endif
	  else if (bind(desc, (struct sockaddr *)&sockaddr,
	    sizeof(sockaddr)) == SOCKET_ERROR)
	    {
	      NSLog(@"unable to bind to port %s:%d - %s",
		inet_ntoa(sockaddr.sin_addr), number, GSLastErrorStr(errno));
	      (void) close(desc);
              DESTROY(port);
	    }
	  else if (listen(desc, 5) == SOCKET_ERROR)
	    {
	      NSLog(@"unable to listen on port - %s", GSLastErrorStr(errno));
	      (void) close(desc);
	      DESTROY(port);
	    }
	  else if (getsockname(desc, (struct sockaddr*)&sockaddr, &i)
	    == SOCKET_ERROR)
	    {
	      NSLog(@"unable to get socket name - %s", GSLastErrorStr(errno));
	      (void) close(desc);
	      DESTROY(port);
	    }
	  else
	    {
	      /*
	       * Set up the listening descriptor and the actual TCP port
	       * number (which will have been set to a real port number when
	       * we did the 'bind' call.
	       */
	      port->listener = desc;
	      port->portNum = GSSwapBigI16ToHost(sockaddr.sin_port); 
	      /*
	       * Make sure we have the map table for this port.
	       */
	      thePorts = (NSMapTable*)NSMapGet(tcpPortMap,
		(void*)(gsaddr)port->portNum);
	      if (thePorts == 0)
		{
		  /*
		   * No known ports with this port number -
		   * create the map table to add the new port to.
		   */ 
		  thePorts = NSCreateMapTable(NSObjectMapKeyCallBacks,
		    NSNonOwnedPointerMapValueCallBacks, 0);
		  NSMapInsert(tcpPortMap, (void*)(gsaddr)port->portNum,
		    (void*)thePorts);
		}
	      /*
	       * Ok - now add the port for the host
	       */
	      NSMapInsert(thePorts, (void*)aHost, (void*)port);
	      NSDebugMLLog(@"NSPort", @"Created listening port: %@", port);
	    }
	}
      else
	{
	  /*
	   * Make sure we have the map table for this port.
	   */
	  port->portNum = number;
	  thePorts = (NSMapTable*)NSMapGet(tcpPortMap, (void*)(gsaddr)number);
	  if (thePorts == 0)
	    {
	      /*
	       * No known ports within this port number -
	       * create the map table to add the new port to.
	       */ 
	      thePorts = NSCreateMapTable(NSIntMapKeyCallBacks,
			      NSNonOwnedPointerMapValueCallBacks, 0);
	      NSMapInsert(tcpPortMap, (void*)(gsaddr)number, (void*)thePorts);
	    }
	  /*
	   * Record the port by host.
	   */
	  NSMapInsert(thePorts, (void*)aHost, (void*)port);
	  NSDebugMLLog(@"NSPort", @"Created speaking port: %@", port);
	}
    }
  else
    {
      RETAIN(port);
      NSDebugMLLog(@"NSPort", @"Using pre-existing port: %@", port);
    }
  IF_NO_GC(AUTORELEASE(port));

  M_UNLOCK(tcpPortLock);
  return port;
}

- (void) addHandle: (GSTcpHandle*)handle forSend: (BOOL)send
{
  M_LOCK(myLock);
  if (send == YES)
    {
      if (handle->caller == YES)
	handle->sendPort = GS_GC_HIDE(self);
      else
	ASSIGN(handle->sendPort, self);
    }
  else
    {
      handle->recvPort = GS_GC_HIDE(self);
    }
  NSMapInsert(handles, (void*)(gsaddr)[handle descriptor], (void*)handle);
  M_UNLOCK(myLock);
}

- (NSString*) address
{
  return address;
}

- (id) copyWithZone: (NSZone*)zone
{
  return RETAIN(self);
}

- (void) dealloc
{
  [self gcFinalize];
  DESTROY(host);
  TEST_RELEASE(address);
  [super dealloc];
}

- (NSString*) description
{
  NSMutableString	*desc;

  desc = [NSMutableString stringWithFormat: @"NSPort on host with details -\n"
    @"%@\n", host];
  if (address == nil)
    {
      [desc appendFormat: @"  IP address - any\n"];
    }
  else
    {
      [desc appendFormat: @"  IP address - %@\n", address];
    }
  [desc appendFormat: @"  TCP port - %d\n", portNum];
  return desc;
}

- (void) gcFinalize
{
  NSDebugMLLog(@"NSPort", @"NSSocketPort 0x%x finalized", self);
  [self invalidate];
}

/*
 * This is a callback method used by the NSRunLoop class to determine which
 * descriptors to watch for the port.
 */
- (void) getFds: (SOCKET*)fds count: (int*)count
{
  NSMapEnumerator	me;
  SOCKET		sock;
  GSTcpHandle		*handle;
  id			recvSelf;

  M_LOCK(myLock);

  /*
   * Make sure there is enough room in the provided array.
   */
  NSAssert(*count > (int)NSCountMapTable(handles),
    NSInternalInconsistencyException);

  /*
   * Put in our listening socket.
   */
  *count = 0;
  if (listener >= 0)
    {
      fds[(*count)++] = listener;
    }

  /*
   * Enumerate all our socket handles, and put them in as long as they
   * are to be used for receiving.
   */
  recvSelf = GS_GC_HIDE(self);
  me = NSEnumerateMapTable(handles);
  while (NSNextMapEnumeratorPair(&me, (void*)&sock, (void*)&handle))
    {
      if (handle->recvPort == recvSelf)
	{
	  fds[(*count)++] = sock;
	}
    }
  NSEndMapTableEnumeration(&me);
  M_UNLOCK(myLock);
}

- (GSTcpHandle*) handleForPort: (NSSocketPort*)recvPort beforeDate: (NSDate*)when
{
  NSMapEnumerator	me;
  SOCKET		sock;
#ifndef	BROKEN_SO_REUSEADDR
  int			opt = 1;
#endif
  GSTcpHandle		*handle = nil;

  M_LOCK(myLock);
  /*
   * Enumerate all our socket handles, and look for one with port.
   */
  me = NSEnumerateMapTable(handles);
  while (NSNextMapEnumeratorPair(&me, (void*)&sock, (void*)&handle))
    {
      if ([handle recvPort] == recvPort)
	{
	  M_UNLOCK(myLock);
	  NSEndMapTableEnumeration(&me);
	  return handle;
	}
    }
  NSEndMapTableEnumeration(&me);

  /*
   * Not found ... create a new handle.
   */
  handle = nil;
  if ((sock = socket(AF_INET, SOCK_STREAM, PF_UNSPEC)) == INVALID_SOCKET)
    {
      NSLog(@"unable to create socket - %s", GSLastErrorStr(errno));
    }
#ifndef	BROKEN_SO_REUSEADDR
  /*
   * Under decent systems, SO_REUSEADDR means that the port can be reused
   * immediately that this process exits.  Under some it means
   * that multiple processes can serve the same port simultaneously.
   * We don't want that broken behavior!
   */
  else if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (char*)&opt,
    sizeof(opt)) < 0)
    {
      (void)close(sock);
      NSLog(@"unable to set reuse on socket - %s", GSLastErrorStr(errno));
    }
#endif
  else if ((handle = [GSTcpHandle handleWithDescriptor: sock]) == nil)
    {
      (void)close(sock);
      NSLog(@"unable to create GSTcpHandle - %s", GSLastErrorStr(errno));
    }
  else
    {
      [recvPort addHandle: handle forSend: NO];
    }
  M_UNLOCK(myLock);
  /*
   * If we succeeded in creating a new handle - connect to remote host.
   */
  if (handle != nil)
    {
      if ([handle connectToPort: self beforeDate: when] == NO)
	{
	  [handle invalidate];
	  handle = nil;
	}
    }
  return handle;
}

- (void) handlePortMessage: (NSPortMessage*)m
{
  id	d = [self delegate];

  if (d == nil)
    {
      NSDebugMLLog(@"NSPort", @"No delegate to handle incoming message", 0);
      return;
    }
  if ([d respondsToSelector: @selector(handlePortMessage:)] == NO)
    {
      NSDebugMLLog(@"NSPort", @"delegate doesn't handle messages", 0);
      return;
    }
  [d handlePortMessage: m];
}

- (unsigned) hash
{
  return (unsigned)portNum;
}

- (NSHost*) host
{
  return host;
}

- (id) init
{
  RELEASE(self);
  self = [tcpPortClass new];
  return self;
}

- (void) invalidate
{
  if ([self isValid] == YES)
    {
      M_LOCK(myLock);

      if ([self isValid] == YES)
	{
	  NSMapTable	*thePorts;
	  NSArray	*handleArray;
	  unsigned	i;

	  M_LOCK(tcpPortLock);
	  thePorts = NSMapGet(tcpPortMap, (void*)(gsaddr)portNum);
	  if (thePorts != 0)
	    {
	      if (listener >= 0)
		{
		  (void) close(listener);
		  listener = -1;
		}
	      NSMapRemove(thePorts, (void*)host);
	    }
	  M_UNLOCK(tcpPortLock);

	  if (handles != 0)
	    {
	      handleArray = NSAllMapTableValues(handles);
	      i = [handleArray count];
	      while (i-- > 0)
		{
		  GSTcpHandle	*handle = [handleArray objectAtIndex: i];

		  [handle invalidate];
		}
	      /*
	       * We permit mutual recursive invalidation, so the handles map
	       * may already have been destroyed.
	       */
	      if (handles != 0)
		{
		  NSFreeMapTable(handles);
		  handles = 0;
		}
	    }
	  [[NSSocketPortNameServer sharedInstance] removePort: self];
	  [super invalidate];
	}
      M_UNLOCK(myLock);
    }
}

- (BOOL) isEqual: (id)anObject
{
  if (anObject == self)
    {
      return YES;
    }
  if ([anObject class] == [self class])
    {
      NSSocketPort	*o = (NSSocketPort*)anObject;

      if (o->portNum == portNum && [o->host isEqual: host])
	{
	  return YES;
	}
    }
  return NO;
}

- (gsu16) portNumber
{
  return portNum;
}

- (void) receivedEvent: (void*)data
                  type: (RunLoopEventType)type
		 extra: (void*)extra
	       forMode: (NSString*)mode
{
  SOCKET	desc = (SOCKET)(gsaddr)extra;
  GSTcpHandle	*handle;

  if (desc == listener)
    {
      struct sockaddr_in	sockAddr;
      int			size = sizeof(sockAddr);

      desc = accept(listener, (struct sockaddr*)&sockAddr, &size);
      if (desc == INVALID_SOCKET)
        {
	  NSDebugMLLog(@"NSPort", @"accept failed - handled in other thread?");
        }
      else
	{
	  /*
	   * Create a handle for the socket and set it up so we are its
	   * receiving port, and it's waiting to get the port name from
	   * the other end.
	   */
	  handle = [GSTcpHandle handleWithDescriptor: desc];
	  memcpy(&handle->sockAddr, &sockAddr, sizeof(sockAddr));
	  handle->defaultAddress = RETAIN([NSString stringWithCString:
	    inet_ntoa(sockAddr.sin_addr)]);

	  [handle setState: GS_H_ACCEPT];
	  [self addHandle: handle forSend: NO];
	}
    }
  else
    {
      M_LOCK(myLock);
      handle = (GSTcpHandle*)NSMapGet(handles, (void*)(gsaddr)desc);
      IF_NO_GC(AUTORELEASE(RETAIN(handle)));
      M_UNLOCK(myLock);
      if (handle == nil)
	{
	  const char	*t;

	  if (type == ET_RDESC) t = "rdesc";
	  else if (type == ET_WDESC) t = "wdesc";
	  else if (type == ET_EDESC) t = "edesc";
	  else if (type == ET_RPORT) t = "rport";
	  else t = "unknown";
	  NSLog(@"No handle for event %s on descriptor %d", t, desc);
	  [[runLoopClass currentRunLoop] removeEvent: extra
						type: type
					     forMode: mode
						 all: YES];
	}
      else
	{
	  [handle receivedEvent: data type: type extra: extra forMode: mode];
	}
    }
}

/*
 * This is called when a tcp/ip socket connection is broken.  We remove the
 * connection handle from this port and, if this was the last handle to a
 * remote port, we invalidate the port.
 */
- (void) removeHandle: (GSTcpHandle*)handle
{
  M_LOCK(myLock);
  if ([handle sendPort] == self)
    {
      if (handle->caller != YES)
	{
	  /*
	   * This is a handle for a send port, and the handle was not formed
	   * by calling the remote process, so this port object must have
	   * been created to deal with an incoming connection and will have
	   * been retained - we must therefore release this port since the
	   * handle no longer uses it.
	   */
	  AUTORELEASE(self);
	}
      handle->sendPort = nil;
    }
  if ([handle recvPort] == self)
    {
      handle->recvPort = nil;
    }
  NSMapRemove(handles, (void*)(gsaddr)[handle descriptor]);
  if (listener < 0 && NSCountMapTable(handles) == 0)
    {
      [self invalidate];
    }
  M_UNLOCK(myLock);
}

/*
 * This returns the amount of space that a port coder should reserve at the
 * start of its encoded data so that the NSSocketPort can insert header info
 * into the data.
 * The idea is that a message consisting of a single data item with space at
 * the start can be written directly without having to copy data to another
 * buffer etc.
 */
- (unsigned int) reservedSpaceLength
{
  return sizeof(GSPortItemHeader) + sizeof(GSPortMsgHeader);
}

- (BOOL) sendBeforeDate: (NSDate*)when
		  msgid: (int)msgId
             components: (NSMutableArray*)components
                   from: (NSPort*)receivingPort
               reserved: (unsigned)length
{
  BOOL		sent = NO;
  GSTcpHandle	*h;
  unsigned	rl;

  if ([self isValid] == NO)
    {
      return NO;
    }
  if ([components count] == 0)
    {
      NSLog(@"empty components sent");
      return NO;
    }
  /*
   * If the reserved length in the first data object is wrong - we have to
   * fail, unless it's zero, in which case we can insert a data object for
   * the header.
   */
  rl = [self reservedSpaceLength];
  if (length != 0 && length != rl)
    {
      NSLog(@"bad reserved length - %u", length);
      return NO;
    }
  if ([receivingPort isKindOfClass: tcpPortClass] == NO)
    {
      NSLog(@"woah there - receiving port is not the correct type");
      return NO;
    }

  h = [self handleForPort: (NSSocketPort*)receivingPort beforeDate: when];
  if (h != nil)
    {
      NSMutableData	*header;
      unsigned		hLength;
      unsigned		l;
      GSPortItemHeader	*pih;
      GSPortMsgHeader	*pmh;
      unsigned		c = [components count];
      unsigned		i;
      BOOL		pack = YES;

      /*
       * Ok - ensure we have space to insert header info.
       */
      if (length == 0 && rl != 0)
	{
	  header = [[mutableDataClass alloc] initWithCapacity: NETBLOCK];

	  [header setLength: rl];
	  [components insertObject: header atIndex: 0];
	  RELEASE(header);
	} 

      header = [components objectAtIndex: 0];
      /*
       * The Item header contains the item type and the length of the
       * data in the item (excluding the item header itsself).
       */
      hLength = [header length];
      l = hLength - sizeof(GSPortItemHeader);
      pih = (GSPortItemHeader*)[header mutableBytes];
      pih->type = GSSwapHostI32ToBig(GSP_HEAD);
      pih->length = GSSwapHostI32ToBig(l);

      /*
       * The message header contains the message Id and the original count
       * of components in the message (excluding any extra component added
       * simply to hold the header).
       */
      pmh = (GSPortMsgHeader*)&pih[1];
      pmh->mId = GSSwapHostI32ToBig(msgId);
      pmh->nItems = GSSwapHostI32ToBig(c);

      /*
       * Now insert item header information as required.
       * Pack as many items into the initial data object as possible, up to
       * a maximum of NETBLOCK bytes.  This is to try to get a single,
       * efficient write operation if possible.
       */
      for (i = 1; i < c; i++)
	{
	  id	o = [components objectAtIndex: i];

	  if ([o isKindOfClass: [NSData class]])
	    {
	      GSPortItemHeader	*pih;
	      unsigned		h = sizeof(GSPortItemHeader);
	      unsigned		l = [o length];
	      void		*b;

	      if (pack == YES && hLength + l + h <= NETBLOCK)
		{
		  [header setLength: hLength + l + h];
		  b = [header mutableBytes];
		  b += hLength;
#if NEED_WORD_ALIGNMENT
		  /*
		   * When packing data, an item may not be aligned on a
		   * word boundary, so we work with an aligned buffer
		   * and use memcmpy()
		   */
		  if ((hLength % wordAlign) != 0)
		    {
		      GSPortItemHeader	itemHeader;

		      pih = (GSPortItemHeader*)&itemHeader;
		      pih->type = GSSwapHostI32ToBig(GSP_DATA);
		      pih->length = GSSwapHostI32ToBig(l);
		      memcpy(b, (void*)pih, h);
		    }
		  else
		    {
		      pih = (GSPortItemHeader*)b;
		      pih->type = GSSwapHostI32ToBig(GSP_DATA);
		      pih->length = GSSwapHostI32ToBig(l);
		    }
#else
		  pih = (GSPortItemHeader*)b;
		  pih->type = GSSwapHostI32ToBig(GSP_DATA);
		  pih->length = GSSwapHostI32ToBig(l);
#endif
		  memcpy(b+h, [o bytes], l);
		  [components removeObjectAtIndex: i--];
		  c--;
		  hLength += l + h;
		}
	      else
		{
		  NSMutableData	*d;

		  pack = NO;
		  d = [[NSMutableData alloc] initWithLength: l + h];
		  b = [d mutableBytes];
		  pih = (GSPortItemHeader*)b;
		  memcpy(b+h, [o bytes], l);
		  pih->type = GSSwapHostI32ToBig(GSP_DATA);
		  pih->length = GSSwapHostI32ToBig(l);
		  [components replaceObjectAtIndex: i
					withObject: d];
		  RELEASE(d);
		}
	    }
	  else if ([o isKindOfClass: tcpPortClass])
	    {
	      NSData	*d = newDataWithEncodedPort(o);
	      unsigned	dLength = [d length];

	      if (pack == YES && hLength + dLength <= NETBLOCK)
		{
		  void	*b;

		  [header setLength: hLength + dLength];
		  b = [header mutableBytes];
		  b += hLength;
		  hLength += dLength;
		  memcpy(b, [d bytes], dLength);
		  [components removeObjectAtIndex: i--];
		  c--;
		}
	      else
		{
		  pack = NO;
		  [components replaceObjectAtIndex: i withObject: d];
		}
	      RELEASE(d);
	    }
	}

      /*
       * Now send the message.
       */
      sent = [h sendMessage: components beforeDate: when];
    }
  return sent;
}

- (NSDate*) timedOutEvent: (void*)data
		     type: (RunLoopEventType)type
		  forMode: (NSString*)mode
{
  return nil;
}

@end


