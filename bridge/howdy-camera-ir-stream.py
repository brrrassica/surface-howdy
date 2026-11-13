#!/usr/bin/env python3
# IR camera bridge unpacker (runs as your user):
# reads IPU3-packed 10-bit greyscale frames (V4L2_PIX_FMT_IPU3_Y10, 'ip3y')
# from argv[1] and writes 8-bit NV12 frames (640x480, neutral chroma) to
# stdout, for ffmpeg to push into the v4l2loopback device (/dev/video20):
#
#   ir-stream.py FIFO | ffmpeg -f rawvideo -pixel_format nv12 \
#       -video_size 640x480 -framerate 30 -i pipe:0 -f v4l2 /dev/video20
#
# Frame layout (source): 480 rows x 832 bytes; each row is 26 groups of
# 32 bytes; each group holds 25 pixels x 10 bits (LSB-first) + 6 pad bits.
import sys

import numpy as np

W, H = 640, 480
STRIDE = ((W * 10 + 7) // 8 + 31) // 32 * 32   # 832
FRAME = STRIDE * H                             # 399360


def unpack(frame):
	arr = np.frombuffer(frame, np.uint8).reshape(H, STRIDE)
	ng = STRIDE // 32
	bits = np.unpackbits(arr, bitorder='little').reshape(H, ng, 256)
	bits = bits[:, :, :250].reshape(H, ng * 25, 10)[:, :W]
	y = (bits * (1 << np.arange(10, dtype=np.uint16))).sum(axis=2).astype(
		np.uint8)
	# NV12: Y plane followed by interleaved U/V; neutral chroma (0x80)
	uv = np.full(W * H // 2, 128, np.uint8)
	return y.tobytes() + uv.tobytes()


def main(cap_path):
	vid = open(cap_path, 'rb', buffering=0)
	out = sys.stdout.buffer
	while True:
		data = b''
		while len(data) < FRAME:
			chunk = vid.read(FRAME - len(data))
			if not chunk:
				return
			data += chunk
		out.write(unpack(data))


if __name__ == '__main__':
	if len(sys.argv) != 2:
		print('usage: ir-stream.py <raw-frame-source>', file=sys.stderr)
		sys.exit(1)
	try:
		main(sys.argv[1])
	except (BrokenPipeError, KeyboardInterrupt):
		pass
