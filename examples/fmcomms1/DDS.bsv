// Copyright (c) 2014 Quanta Research Cambridge, Inc.

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

import Complex::*;
import FixedPoint::*;
import StmtFSM::*;
import BRAM::*;

interface DDS;
   method Action setPhaseAdvance(FixedPoint#(10,32) v);
   method  Complex#(FixedPoint#(2,23)) getValue();
endinterface



module mkDDS(Empty);
   BRAM_Configure cfg = defaultValue;
   cfg.memorySize = 1024;
   cfg.loadFormat = tagged Binary "sine.bin";
   BRAM1Port#(Bit#(10), Complex#(FixedPoint#(2,23))) ram <-mkBRAM1Server(cfg);
   Reg#(FixedPoint#(2,23)) phase <- mkReg(0);
   Reg#(FixedPoint#(2,23)) phaseAdvance <- mkReg(0);
   Reg#(UInt#(12)) idx <- mkReg(0);
   Stmt dumpRam =   
   seq
      for (idx <= 0; idx < 1024; idx <= idx + 1)
	 seq
	    ram.portA.request.put(BRAMRequest{write: False, responseOnWrite: False, address: truncate(pack(idx)), datain: ?});
	   action
	      let v <- ram.portA.response.get();
	      $display("adr %d", idx);
	      $write( "re " ) ; fxptWrite( 10, v.rel ) ; $display("" ) ;
	      $write( "im " ) ; fxptWrite( 10, v.img ) ; $display("" ) ;
	      endaction
	    endseq
   endseq;

   mkAutoFSM (dumpRam);
   
   rule filter_phase;
      phase <= phase + phaseAdvance;

   endrule
   
   
endmodule
