/* ir-sink.c: reads raw NV12 frames (640x480) from stdin and streams them
 * into a v4l2loopback device as a proper V4L2 OUTPUT (mmap) writer.
 *
 *   ffmpeg -f rawvideo -pix_fmt nv12 -s 640x480 -i pipe:0 -f v4l2 /dev/video20
 * (equivalent, but as a self-contained helper with deterministic ioctls)
 *
 *   ir-sink /dev/video20 < unpacked-nv12-stream
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define W 640
#define H 480
#define FRAME_SIZE (W * H * 3 / 2)   /* NV12 */

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do {
		r = ioctl(fd, req, arg);
	} while (r == -1 && errno == EINTR);
	return r;
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/video20";
	int fd, nbufs, i;
	struct v4l2_format fmt;
	struct v4l2_requestbuffers req;
	struct v4l2_buffer buf;
	struct buffer { void *start; size_t length; } *bufs;
	unsigned char *frame;
	ssize_t got;
	size_t off;

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror("open loopback");
		return 1;
	}

	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	fmt.fmt.pix.width = W;
	fmt.fmt.pix.height = H;
	fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;
	fmt.fmt.pix.bytesperline = W;
	fmt.fmt.pix.sizeimage = FRAME_SIZE;
	if (xioctl(fd, VIDIOC_S_FMT, &fmt) == -1) {
		perror("S_FMT");
		return 1;
	}

	memset(&req, 0, sizeof(req));
	req.count = 4;
	req.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(fd, VIDIOC_REQBUFS, &req) == -1) {
		perror("REQBUFS");
		return 1;
	}
	nbufs = req.count;
	fprintf(stderr, "ir-sink: %d output buffers\n", nbufs);

	bufs = calloc(nbufs, sizeof(*bufs));
	for (i = 0; i < nbufs; i++) {
		memset(&buf, 0, sizeof(buf));
		buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
		buf.memory = V4L2_MEMORY_MMAP;
		buf.index = i;
		if (xioctl(fd, VIDIOC_QUERYBUF, &buf) == -1) {
			perror("QUERYBUF");
			return 1;
		}
		bufs[i].length = buf.length;
		bufs[i].start = mmap(NULL, buf.length, PROT_WRITE, MAP_SHARED,
				     fd, buf.m.offset);
		if (bufs[i].start == MAP_FAILED) {
			perror("mmap");
			return 1;
		}
		fprintf(stderr, "ir-sink: buf %d length %zu offset %u\n",
			i, bufs[i].length, buf.m.offset);
		memset(&buf, 0, sizeof(buf));
		buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
		buf.memory = V4L2_MEMORY_MMAP;
		buf.index = i;
		if (xioctl(fd, VIDIOC_QBUF, &buf) == -1) {
			perror("QBUF");
			return 1;
		}
	}

	i = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	if (xioctl(fd, VIDIOC_STREAMON, &i) == -1) {
		perror("STREAMON");
		return 1;
	}

	frame = malloc(FRAME_SIZE);
	for (;;) {
		off = 0;
		while (off < (size_t)FRAME_SIZE) {
			got = read(0, frame + off, FRAME_SIZE - off);
			if (got <= 0) {
				if (got == 0 && off == 0)
					goto done;  /* clean EOF */
				if (got == 0) {
					fprintf(stderr,
						"ir-sink: short frame at EOF\n");
					goto done;
				}
				perror("read stdin");
				return 1;
			}
			off += got;
		}

		memset(&buf, 0, sizeof(buf));
		buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
		buf.memory = V4L2_MEMORY_MMAP;
		if (xioctl(fd, VIDIOC_DQBUF, &buf) == -1) {
			perror("DQBUF");
			return 1;
		}
		memcpy(bufs[buf.index].start, frame, FRAME_SIZE);
		memset(&buf, 0, sizeof(buf));
		buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
		buf.memory = V4L2_MEMORY_MMAP;
		buf.index = buf.index;
		buf.bytesused = FRAME_SIZE;
		if (xioctl(fd, VIDIOC_QBUF, &buf) == -1) {
			perror("QBUF");
			return 1;
		}
	}

done:
	i = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	xioctl(fd, VIDIOC_STREAMOFF, &i);
	close(fd);
	free(frame);
	return 0;
}
