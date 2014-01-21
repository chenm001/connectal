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
import FIFO::*;
import FIFOF::*;
import SpecialFIFOs :: *;
import Vector::*;
import GetPut::*;
import GetPutF::*;
import ClientServer::*;

// XBSV Libraries
import AxiClientServer::*;
import PortalMemory::*;
import PortalRMemory::*;
import Adapter::*;
import SGList::*;

`ifdef BSIM
import "BDPI" function ActionValue#(Bit#(32)) pareff(Bit#(32) handle, Bit#(32) size);
`endif

//
// @brief AxiDMA provides the configuration and AXI bus interface for DMA
//
// @param dsz Number of bits in the data bus
// @param dbytes Number of bytes in the data bus
//
interface AxiDMAServer#(numeric type dsz, numeric type dbytes);
   interface DMARequest request;
   interface Axi3Client#(40,dsz,dbytes,6) m_axi;
endinterface

interface ConfigureSglist;
   method Action configuring(Bool c);
   method Action page(Bit#(32) tabsel, Bit#(PageIdxSize) off, Bit#(TSub#(40,SGListPageShift)) addr);
   method Action readSglist(Bit#(32) pref, Bit#(DmaAddrSize) addr);
endinterface

interface AxiDMAWriteInternal#(numeric type dsz, numeric type dbytes);
   interface DMAWrite write;
   interface Axi3Client#(40,dsz,dbytes,6) m_axi;
   interface ConfigureSglist configure;
endinterface

interface AxiDMAReadInternal#(numeric type dsz, numeric type dbytes);
   interface DMARead read;
   interface Axi3Client#(40,dsz,dbytes,6) m_axi;
   interface ConfigureSglist configure;
endinterface

typedef enum {Idle, Translate, Address, Data, Done} InternalState deriving(Eq,Bits);
		 
module mkAxiDMAReadInternal#(Integer numRequests, Vector#(numReadClients, DMAReadClient#(dsz)) readClients,
			     DMAIndication dmaIndication)(AxiDMAReadInternal#(dsz,dbytes))
   provisos(Add#(1,a__,dsz),
	    Mul#(dbytes,8,dsz));
   
   SGListMMU#(40) sgl <- mkSGListMMU();
   
   FIFO#(DMAAddressRequest) lreqFifo <- mkPipelineFIFO();
   FIFO#(DMAAddressRequest) reqFifo  <- mkPipelineFIFO();
   FIFO#(DMAAddressRequest) dreqFifo <- mkSizedFIFO(numRequests);
   FIFO#(Bit#(40))        paFifo     <- mkPipelineFIFO();
   FIFO#(DmaChannelId)    chanFifo   <- mkSizedFIFO(numRequests);

   Reg#(DmaChannelId)    selectReg <- mkReg(0);
   Reg#(Bit#(8))         burstReg <- mkReg(0);   
   Reg#(Bool)            isConfiguring <- mkReg(False);
   Reg#(Bool)            debugReg <- mkReg(False);

   (* descending_urgency = "loadChannel,incSelectReg" *)
   rule incSelectReg;
      let s = selectReg+1;
      if (s == fromInteger(valueOf(numReadClients)))
	 s = 0;
      selectReg <= s;
   endrule
   
   rule sglistEntry if (debugReg);
      let tpl <- sgl.dbgAddrResp();
      let physAddr = tpl_2(tpl);
      dmaIndication.sglistEntry(extend(tpl_1(tpl)), extend(physAddr));
      debugReg <= False;
   endrule

   rule loadChannel if (valueOf(numReadClients) > 0 && !isConfiguring && readClients[selectReg].readData.notFull());
      DMAAddressRequest req = unpack(0);
      if (valueOf(numReadClients) > 0)
	 req <- readClients[selectReg].readReq.get();
      $display("dmaread.loadChannel activeChan=%d handle=%h addr=%h burst=%h", selectReg, req.handle, req.address, req.burstLen);

      if (req.handle > fromInteger(valueOf(NumSGLists)))
	 dmaIndication.badHandle(req.handle, extend(req.address));
      else begin
	 lreqFifo.enq(req);
	 chanFifo.enq(selectReg);
	 sgl.addrReq(truncate(req.handle),req.address);
      end
   endrule
   
   rule checkSglResp if (!debugReg);
      let physAddr <- sgl.addrResp();
      let req = lreqFifo.first();
      lreqFifo.deq();
      if (physAddr <= (1 << valueOf(SGListPageShift))) begin
	 // squash request
	 $display("dmaRead: badAddr handle=%d addr=%h physAddr=%h", req.handle, req.address, physAddr);
	 dmaIndication.badAddr(req.handle, extend(req.address), extend(physAddr));
      end
      else begin
	 reqFifo.enq(req);
	 paFifo.enq(physAddr);
      end
   endrule

   interface ConfigureSglist configure;
       method Action page(Bit#(32) tabsel, Bit#(PageIdxSize) off, Bit#(TSub#(40,SGListPageShift)) addr) if (isConfiguring);
	  sgl.page(truncate(tabsel), off, addr);
       endmethod

       method Action readSglist(Bit#(32) pref, Bit#(DmaAddrSize) addr) if (!debugReg);
	  debugReg <= True;
	  sgl.dbgAddrReq(truncate(pref), addr);
       endmethod
      method Action configuring(Bool c);
	 isConfiguring <= c;
      endmethod
   endinterface

   interface DMARead read;
      method ActionValue#(DmaDbgRec) dbg();
	 return ?;
      endmethod
   endinterface

   interface Axi3Client m_axi;
      interface Get req_ar;
	 method ActionValue#(Axi3ReadRequest#(40,6)) get();
	    let req = reqFifo.first();
	    reqFifo.deq();
	    let physAddr = paFifo.first();
	    paFifo.deq();

	    dreqFifo.enq(req);
	    return Axi3ReadRequest{address:physAddr, len:truncate(req.burstLen-1), id:truncate(req.tag),
				   size: axiBusSize(valueOf(dsz)), burst: 1, prot: 0, cache: 3, lock:0, qos:0};
	 endmethod
      endinterface
      interface Put resp_read;
	 method Action put(Axi3ReadResponse#(dsz,6) response);
	    let activeChan = chanFifo.first();
	    let resp = dreqFifo.first();
	    if (valueOf(numReadClients) > 0)
	       readClients[activeChan].readData.put(DMAData { data: response.data, tag: resp.tag});

	    let burstLen = burstReg;
	    if (burstLen == 0)
	       burstLen = resp.burstLen;

	    if (burstLen == 1) begin
	       dreqFifo.deq();
	       chanFifo.deq();
	    end

	    burstReg <= burstLen-1;
	 endmethod
      endinterface
      interface Get req_aw = ?;
      interface Get resp_write = ?;
      interface Put resp_b = ?;
   endinterface
endmodule


module mkAxiDMAWriteInternal#(Integer numRequests, Vector#(numWriteClients, DMAWriteClient#(dsz)) writeClients,
			      DMAIndication dmaIndication)(AxiDMAWriteInternal#(dsz,dbytes))
   provisos(Add#(1,a__,dsz),
	    Mul#(dbytes,8,dsz));
   SGListMMU#(40) sgl <- mkSGListMMU();
   
   FIFO#(DMAAddressRequest) lreqFifo <- mkPipelineFIFO();
   FIFO#(DMAAddressRequest) reqFifo <- mkFIFO();
   FIFO#(DMAAddressRequest) dreqFifo <- mkSizedFIFO(numRequests);
   FIFO#(Bit#(40))        paFifo     <- mkFIFO();
   FIFO#(DmaChannelId)    chanFifo <- mkSizedFIFO(numRequests);
   FIFO#(DmaChannelId)    respFifo <- mkSizedFIFO(numRequests);

   Reg#(DmaChannelId)    selectReg <- mkReg(0);
   Reg#(Bit#(8))         burstReg <- mkReg(0);   
   Reg#(Bool)            isConfiguring <- mkReg(False);
   Reg#(Bool)            debugReg <- mkReg(False);

   (* descending_urgency = "loadChannel,incSelectReg" *)
   rule incSelectReg;
      let s = selectReg+1;
      if (s == fromInteger(valueOf(numWriteClients)))
	 s = 0;
      selectReg <= s;
   endrule
   
   rule readEntry if (debugReg);
      let tpl <- sgl.dbgAddrResp();
      let physAddr = tpl_2(tpl);
      dmaIndication.sglistEntry(extend(tpl_1(tpl)), extend(physAddr));
      debugReg <= False;
   endrule

   rule loadChannel if (valueOf(numWriteClients) > 0 && !isConfiguring && writeClients[selectReg].writeData.notEmpty());
      DMAAddressRequest req = unpack(0);
      if (valueOf(numWriteClients) > 0)
	 req <- writeClients[selectReg].writeReq.get();
      $display("dmawrite.loadChannel activeChan=%d handle=%h addr=%h burst=%h debugReq=%d", selectReg, req.handle, req.address, req.burstLen, debugReg);

      lreqFifo.enq(req);
      chanFifo.enq(selectReg);
      sgl.addrReq(truncate(req.handle),req.address);
   endrule
   
   rule checkSglResp if (!debugReg);
      let physAddr <- sgl.addrResp();
      let req = lreqFifo.first();
      lreqFifo.deq();
      if (physAddr <= (1 << valueOf(SGListPageShift))) begin
	 // squash request
	 $display("dmaWrite: badAddr handle=%d addr=%h physAddr=%h", req.handle, req.address, physAddr);
	 dmaIndication.badAddr(req.handle, extend(req.address), extend(physAddr));
      end
      else begin
	 reqFifo.enq(req);
	 paFifo.enq(physAddr);
      end
   endrule

   interface ConfigureSglist configure;
      method Action page(Bit#(32) tabsel, Bit#(PageIdxSize) off, Bit#(TSub#(40,SGListPageShift)) addr) if (isConfiguring);
	 sgl.page(truncate(tabsel), off, addr);
      endmethod

      method Action readSglist(Bit#(32) pref, Bit#(DmaAddrSize) addr) if (!debugReg);
	 debugReg <= True;
	 sgl.addrReq(truncate(pref), addr);
      endmethod
      method Action configuring(Bool c);
	 isConfiguring <= c;
      endmethod
   endinterface

   interface DMAWrite write;
      method ActionValue#(DmaDbgRec) dbg();
	 return ?;
      endmethod
   endinterface

   interface Axi3Client m_axi;
   interface Get req_ar = ?;
   interface Put resp_read = ?;
   interface Get req_aw;
      method ActionValue#(Axi3WriteRequest#(40,6)) get();
	 let req = reqFifo.first();
	 reqFifo.deq();
	 let physAddr = paFifo.first();
	 paFifo.deq();
	 $display("dmaWrite addr physAddr=%h burstReg=%d", physAddr, req.burstLen);

	 dreqFifo.enq(req);
	 return Axi3WriteRequest{address:physAddr, len:truncate(req.burstLen-1), id:truncate(req.tag),
				 size: axiBusSize(valueOf(dsz)), burst: 1, prot: 0, cache: 3, lock:0, qos:0};
      endmethod
   endinterface
   interface Get resp_write;
	 method ActionValue#(Axi3WriteData#(dsz, dbytes, 6)) get();
	    let activeChan = chanFifo.first();
	    let resp = dreqFifo.first();
	    DMAData#(dsz) tagdata = unpack(0);
	    if (valueOf(numWriteClients) > 0)
	       tagdata <- writeClients[activeChan].writeData.get();
	    let burstLen = burstReg;
	    if (burstLen == 0)
	       burstLen = resp.burstLen;

	    if (burstLen == 1) begin
	       dreqFifo.deq();
	       chanFifo.deq();
	       respFifo.enq(activeChan);
	    end

	    $display("dmaWrite data data=%h burstLen=%d", tagdata.data, burstLen);

	    burstReg <= burstLen-1;

	    Bit#(1) last = burstLen == 1 ? 1'b1 : 1'b0;

	    return Axi3WriteData { data: tagdata.data, byteEnable: maxBound, last: last, id: truncate(tagdata.tag) };
	 endmethod
      endinterface
      interface Put resp_b;
	 method Action put(Axi3WriteResponse#(6) resp);
	    let activeChan = respFifo.first();
	    respFifo.deq();
	    if (valueOf(numWriteClients) > 0)
	       writeClients[activeChan].writeDone.put(extend(resp.id));
	 endmethod
      endinterface
   endinterface
endmodule

//
// @brief Creates a DMA controller for DMA read and write clients
//
// @param dmaIndication Interface for notifying software
// @param readClients The read clients.
// @param writeClients The writeclients.
//
module mkAxiDMAServer#(DMAIndication dmaIndication,
		       Integer numRequests,
		       Vector#(numReadClients, DMAReadClient#(dsz)) readClients,
		       Vector#(numWriteClients, DMAWriteClient#(dsz)) writeClients)
   (AxiDMAServer#(dsz,dbytes))
   provisos (Add#(1,a__,dsz),
	     Mul#(dbytes,8,dsz));

   AxiDMAReadInternal#(dsz,dbytes) reader <- mkAxiDMAReadInternal(numRequests, readClients, dmaIndication);
   AxiDMAWriteInternal#(dsz,dbytes) writer <- mkAxiDMAWriteInternal(numRequests, writeClients, dmaIndication);

   Reg#(Bit#(TSub#(40,SGListPageShift))) addrReg <- mkReg(0);
   Reg#(Bit#(32))                        prefReg <- mkReg(0);
   Reg#(Bit#(PageIdxSize))               lenReg  <- mkReg(0);
   Reg#(Bit#(PageIdxSize))               idxReg  <- mkReg(0);
   
   let page_shift = fromInteger(valueOf(SGListPageShift));

   rule write_pages(idxReg < lenReg);
      idxReg <= idxReg + 1;
      addrReg <= addrReg + 1;
      writer.configure.page(prefReg,idxReg,addrReg);
      reader.configure.page(prefReg,idxReg,addrReg);
      if(idxReg+1 == lenReg) begin
	 reader.configure.configuring(False);
	 writer.configure.configuring(False);
	 dmaIndication.sglistResp(prefReg, extend(idxReg), extend(addrReg));
      end
   endrule

   interface DMARequest request;
      method Action getStateDbg(ChannelType rc);
	 let rv = ?;
	 if (rc == Read)
	    rv <- reader.read.dbg;
	 else
	    rv <- writer.write.dbg;
	 dmaIndication.reportStateDbg(rv);
      endmethod
      method Action sglist(Bit#(32) pref, Bit#(40) addr, Bit#(32) len) if (idxReg == lenReg);
	 let idx = idxReg;
	 if (prefReg != pref)
	    idx = 0;
	 prefReg <= pref;
	 lenReg  <= truncate(len >> page_shift) + idx;
	 idxReg <= idx;
	 if (addr == 0 && len == 0) begin // sw marks end-of-list with zeros
	    dmaIndication.sglistResp(pref, extend(idx), 0);
	 end
	 else if (addr == 0 && len > 0) begin
	    $display("sglist badAddr pref=%d idx=%h addr=%h", pref, idx, addr);
	    dmaIndication.badAddr(pref, extend(idx), extend(addr >> page_shift));
	 end
	 else begin
`ifdef BSIM
	    let va <- pareff(pref, len);
	    addr[39:32] = truncate(pref);
	    addr[31:0] = 0;
	    $display("sglist.pareff handle=%d addr=%h len=%h", pref, addr, len);
`endif
	    addrReg <= truncate(addr >> page_shift);
	    reader.configure.configuring(True);
	    writer.configure.configuring(True);
	 end
      endmethod
      method Action readSglist(ChannelType rc, Bit#(32) handle, Bit#(32) addr);
	 if (rc == Read)
	    reader.configure.readSglist(handle, truncate(addr));
	 else
	    writer.configure.readSglist(handle, truncate(addr));
      endmethod
   endinterface
   interface Axi3Client m_axi;
      interface Get req_ar = reader.m_axi.req_ar;
      interface Put resp_read = reader.m_axi.resp_read;

      interface Get req_aw = writer.m_axi.req_aw;
      interface Get resp_write = writer.m_axi.resp_write;
      interface Put resp_b = writer.m_axi.resp_b;
   endinterface
endmodule

