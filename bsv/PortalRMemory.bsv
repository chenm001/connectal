// Copyright (c) 2013 Quanta Research Cambridge, Inc.

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.


// BSV Libraries
import FIFOF::*;
import Adapter::*;
import GetPutF::*;
import Vector::*;
import ClientServer::*;
import BRAMFIFO::*;

// XBSV Libraries
import PortalMemory::*;
import BRAMFIFOFLevel::*;

typedef Bit#(32) DmaMemHandle;

typedef 24 DmaAddrSize;
// SGListMaxPages is derived from this

typedef struct {
   DmaMemHandle handle;
   Bit#(DmaAddrSize)  address;
   Bit#(8) burstLen;
   Bit#(6)  tag;
   } DMAAddressRequest deriving (Bits);
typedef struct {
   Bit#(dsz) data;
   Bit#(6) tag;
   } DMAData#(numeric type dsz) deriving (Bits);

interface DMAReadClient#(numeric type dsz);
   interface GetF#(DMAAddressRequest)    readReq;
   interface PutF#(DMAData#(dsz)) readData;
endinterface

interface DMAWriteClient#(numeric type dsz);
   interface GetF#(DMAAddressRequest)    writeReq;
   interface GetF#(DMAData#(dsz)) writeData;
   interface PutF#(Bit#(6))       writeDone;
endinterface

interface DMAReadServer#(numeric type dsz);
   interface PutF#(DMAAddressRequest) readReq;
   interface GetF#(DMAData#(dsz))     readData;
endinterface

interface DMAWriteServer#(numeric type dsz);
   interface PutF#(DMAAddressRequest) writeReq;
   interface PutF#(DMAData#(dsz))     writeData;
   interface GetF#(Bit#(6))           writeDone;
endinterface

//
// @brief A buffer for reading from a bus of width bsz.
//
// @param bsz The number of bits in the bus.
// @param maxBurst The number of words to buffer
//
interface DMAReadBuffer#(numeric type bsz, numeric type maxBurst);
   interface DMAReadServer #(bsz) dmaServer;
   interface DMAReadClient#(bsz) dmaClient;
endinterface

//
// @brief A buffer for writing to a bus of width bsz.
//
// @param bsz The number of bits in the bus.
// @param maxBurst The number of words to buffer
//
interface DMAWriteBuffer#(numeric type bsz, numeric type maxBurst);
   interface DMAWriteServer#(bsz) dmaServer;
   interface DMAWriteClient#(bsz) dmaClient;
endinterface

//
// @brief Makes a DMA buffer for reading wordSize words from memory.
//
// @param dsz The width of the bus in bits.
// @param maxBurst The max number of words to transfer per request.
//
module mkDMAReadBuffer(DMAReadBuffer#(dsz, maxBurst))
   provisos(Add#(1,a__,dsz),
	    Add#(b__, TAdd#(1,TLog#(maxBurst)), 8));

   FIFOFLevel#(DMAData#(dsz),maxBurst)  readBuffer <- mkBRAMFIFOFLevel;
   FIFOF#(DMAAddressRequest)        reqOutstanding <- mkFIFOF();
   Ratchet#(TAdd#(1,TLog#(maxBurst))) unfulfilled <- mkRatchet(0);
   
   // only issue the readRequest when sufficient buffering is available.  This includes the bufering we have already comitted.
   Bit#(TAdd#(1,TLog#(maxBurst))) sreq = pack(satPlus(Sat_Bound, unpack(truncate(reqOutstanding.first.burstLen)), unfulfilled.read()));

   interface DMAReadServer dmaServer;
      interface PutF readReq = toPutF(reqOutstanding);
      interface GetF readData = toGetF(readBuffer);
   endinterface
   interface DMAReadClient dmaClient;
      interface GetF readReq;
	 method ActionValue#(DMAAddressRequest) get if (readBuffer.lowWater(sreq));
	    reqOutstanding.deq;
	    unfulfilled.increment(unpack(truncate(reqOutstanding.first.burstLen)));
	    return reqOutstanding.first;
	 endmethod
         method Bool notEmpty();
	    return readBuffer.lowWater(sreq);
	 endmethod
      endinterface
      interface PutF readData;
	 method Action put(DMAData#(dsz) x);
	    readBuffer.fifo.enq(x);
	    unfulfilled.decrement(1);
	 endmethod
	 method notFull();
	    return readBuffer.fifo.notFull();
	 endmethod
      endinterface
   endinterface
endmodule

//
// @brief Makes a DMA channel for writing wordSize words from memory.
//
// @param bsz The width of the bus in bits.
// @param maxBurst The max number of words to transfer per request.
//
module mkDMAWriteBuffer(DMAWriteBuffer#(bsz, maxBurst))
   provisos(Add#(1,a__,bsz),
	    Add#(b__, TAdd#(1, TLog#(maxBurst)), 8));

   FIFOFLevel#(DMAData#(bsz),maxBurst) writeBuffer <- mkBRAMFIFOFLevel;
   FIFOF#(DMAAddressRequest)        reqOutstanding <- mkFIFOF();
   FIFOF#(Bit#(6))                        doneTags <- mkFIFOF();
   Ratchet#(TAdd#(1,TLog#(maxBurst)))  unfulfilled <- mkRatchet(0);
   
   // only issue the writeRequest when sufficient data is available.  This includes the data we have already comitted.
   Bit#(TAdd#(1,TLog#(maxBurst))) sreq = pack(satPlus(Sat_Bound, unpack(truncate(reqOutstanding.first.burstLen)), unfulfilled.read()));

   interface DMAWriteServer dmaServer;
      interface PutF writeReq = toPutF(reqOutstanding);
      interface PutF writeData = toPutF(writeBuffer);
      interface GetF writeDone = toGetF(doneTags);
   endinterface
   interface DMAWriteClient dmaClient;
      interface GetF writeReq;
	 method ActionValue#(DMAAddressRequest) get if (writeBuffer.highWater(sreq));
	    reqOutstanding.deq;
	    unfulfilled.increment(unpack(truncate(reqOutstanding.first.burstLen)));
	    return reqOutstanding.first;
	 endmethod
	 method Bool notEmpty();
	    return writeBuffer.highWater(sreq);
	 endmethod
      endinterface
      interface GetF writeData;
	 method ActionValue#(DMAData#(bsz)) get();
	    unfulfilled.decrement(1);
	    writeBuffer.fifo.deq;
	    return writeBuffer.fifo.first;
	 endmethod
	 method Bool notEmpty();
	    return writeBuffer.fifo.notEmpty;
	 endmethod
      endinterface
      interface PutF writeDone = toPutF(doneTags);
   endinterface
endmodule

interface DMARead;
   method ActionValue#(DmaDbgRec) dbg();
endinterface

interface DMAWrite;
   method ActionValue#(DmaDbgRec) dbg();
endinterface

