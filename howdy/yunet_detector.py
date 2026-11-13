# yunet_detector.py - OpenCV YuNet (DNN) face detector adapter for Howdy.
#
# The dlib detectors struggle with IR frames: the HOG detector never fires
# on strobe-lit infrared faces, and the CNN takes 20+ s per frame on this
# CPU. YuNet is ~20 ms and detects IR faces reliably.
#
# The adapter mimics the dlib detector call signature used by Howdy
# (detector(img, upsample) -> iterable of dlib rectangles). Detection runs
# on the raw BGR frame; CLAHE/preprocessing must NOT be applied first (it
# kills YuNet on IR frames). Set .is_color = True so callers pass the raw
# color frame instead of the grayscale one.
import os

import cv2
import dlib

# The OpenCV 5 "new graph engine" logs a warning for every YuNet
# inference (targets unsupported); keep errors, drop the noise.
try:
	cv2.utils.logging.setLogLevel(cv2.utils.logging.LOG_LEVEL_ERROR)
except Exception:
	pass


class YunetDetector:
	is_color = True

	# IR frames produce large phantom boxes (vignette / shirt texture).
	# A real head at this camera's FOV is roughly square and 80-230 px
	# wide; reject anything implausible before scoring.
	def _plausible(self, w, h):
		if w < 80 or w > 230:
			return False
		ar = h / w
		return 0.55 <= ar <= 1.45

	def __init__(self, model_path, score=0.6):
		self.net = cv2.FaceDetectorYN.create(
			model_path, "", (640, 480), score_threshold=0.45)

	def __call__(self, img, upsample=1):
		bgr = img if img.ndim == 3 else cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
		self.net.setInputSize((bgr.shape[1], bgr.shape[0]))
		ret, faces = self.net.detect(bgr)
		rects = dlib.rectangles()
		if faces is not None:
			h, w = bgr.shape[:2]
			for f in faces:
				fx, fy, fw, fh = [int(v) for v in f[:4]]
				if not self._plausible(fw, fh):
					continue
				rects.append(dlib.rectangle(
					max(fx, 0), max(fy, 0), min(fx + fw, w), min(fy + fh, h)))
		return rects


def maybe_create(howdy_dir):
	"""Returns a YunetDetector when the model file is available, else None."""
	path = os.path.join(howdy_dir, "dlib-data", "yunet.onnx")
	if os.path.isfile(path):
		return YunetDetector(path)
	return None
