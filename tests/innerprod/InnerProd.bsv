
import GetPut::*;
import Clocks::*;
import FIFO::*;
import FIFOF::*;
import GetPut::*;
import Connectable::*;

import HostInterface::*;
import Dsp48E1::*;
import InnerProdInterface::*;
import ConnectalBramFifo::*;

interface InnerProd;
   interface InnerProdRequest request;
endinterface

interface InnerProdTile;
   interface Put#(Tuple7#(Int#(16),Int#(16),Bool,Bool,Bit#(4),Bit#(5),Bit#(7))) request;
   interface Get#(Int#(48)) response;
endinterface

(* synthesize *)
module mkInnerProdTile(InnerProdTile);

   let dsp <- mkDsp48E1();

   interface Put request;
      method Action put(Tuple7#(Int#(16),Int#(16),Bool,Bool,Bit#(4),Bit#(5),Bit#(7)) req);
	 match { .a, .b, .first, .last, .alumode, .inmode, .opmode } = req;
	 dsp.a(extend(pack(a)));
	 dsp.b(extend(pack(b)));
	 dsp.c('h22);
	 dsp.d(0);
	 //let opmode = 7'h45; // p = M + P
	 //if (first)
	 //opmode = 7'h05; // P = M + 0
	 dsp.opmode(opmode);
	 dsp.inmode(inmode);
	 dsp.alumode(alumode);
	 dsp.last(pack(last));
      endmethod
   endinterface
   interface Get response;
      method ActionValue#(Int#(48)) get();
	 $display("InnerProdTile response.get %h", dsp.p());
	 return unpack(dsp.p());
      endmethod
   endinterface
endmodule

module mkInnerProd#(
`ifdef IMPORT_HOSTIF
		    HostInterface host,
`endif
		    InnerProdIndication ind)(InnerProd);

   let defaultClock <- exposeCurrentClock;
   let defaultReset <- exposeCurrentReset;
`ifdef IMPORT_HOSTIF
   let derivedClock = host.derivedClock;
`else
   let derivedClock = defaultClock;
`endif
   let derivedReset <- mkAsyncReset(2, defaultReset, derivedClock);
   let optionalReset = derivedReset; // noReset
   let syncIn <- mkSyncFIFO(16, defaultClock, defaultReset, derivedClock);
   FIFOF#(Int#(48)) bramFifo <- mkDualClockBramFIFOF(derivedClock, derivedReset, defaultClock, defaultReset);

   Reg#(Bit#(32)) cycles <- mkReg(0, clocked_by derivedClock, reset_by derivedReset);
   rule cyclesRule;
      cycles <= cycles+1;
   endrule

   let tile <- mkInnerProdTile(clocked_by derivedClock, reset_by optionalReset);
   rule syncRequestRule;
      let req <- toGet(syncIn).get();
      $display("syncRequestRule a=%h b=%h", tpl_1(req), tpl_2(req));
      tile.request.put(req);
   endrule
   mkConnection(tile.response, toPut(bramFifo), clocked_by derivedClock, reset_by derivedReset);
   rule indRule;
      let r <- toGet(bramFifo).get();
      $display("%d: indRule v=%x %d", cycles, r, r);
      ind.innerProd(pack(r));
   endrule

   interface InnerProdRequest request;
      method Action innerProd(Bit#(16) a, Bit#(16) b, Bool first, Bool last, Bit#(4) alumode, Bit#(5) inmode, Bit#(7) opmode);
	 $display("request.innerProd a=%h b=%h", a, b);
	 syncIn.enq(tuple7(unpack(a),unpack(b),first,last, alumode, inmode, opmode));
      endmethod
      method Action finish();
	 $dumpflush();
	 $finish();
      endmethod
   endinterface
endmodule
