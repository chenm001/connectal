/* Copyright (c) 2014 Quanta Research Cambridge, Inc
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#include "Ov7670ControllerRequest.h"
#include "Ov7670ControllerIndication.h"

class Ov7670ControllerIndication : public Ov7670ControllerIndicationWrapper {
  int datacount;
  int gapcount;
public:
  Ov7670ControllerIndication(unsigned int id) : Ov7670ControllerIndicationWrapper(id), datacount(0), gapcount(0) {}
  ~Ov7670ControllerIndication() {}
  virtual void probeResponse(uint8_t data) {
    fprintf(stderr, "i2c response %02x\n", data);
  }
  virtual void vsync(uint32_t cycles, uint8_t href) {
    //fprintf(stderr, "vsync %8d href %d\n", cycles, href);
    if (datacount) {
      fprintf(stderr, "vsync datacount=%8d gapcount=%8d\n", datacount, gapcount);
      datacount = 0;
      gapcount = 0;
    }
  }
  virtual void data(uint8_t first, uint8_t gap, uint8_t data) {
    //if (gap) fprintf(stderr, "data %8x first %d gap %d\n", data, first, gap);
    datacount++;
    if (gap) gapcount++;
  }
};

int main(int argc, const char **argv)
{
  Ov7670ControllerRequestProxy device(IfcNames_Ov7670ControllerRequestS2H);
  Ov7670ControllerIndication deviceResponse(IfcNames_Ov7670ControllerIndicationH2S);
  device.setPowerDown(0);
  device.setReset(1);
  for (int i = 0; i < 10; i++) {
    // product ID: 0x76
    device.probe(0, 21, 0x0a, 0);
    // product VER: 0x70
    device.probe(0, 21, 0x0b, 0);
    // mfg id: 0x7F
    device.probe(0, 21, 0x1c, 0);
    // mfg id: 0xA2
    device.probe(0, 21, 0x1d, 0);
    sleep(1);
  }
  return 0;
}
