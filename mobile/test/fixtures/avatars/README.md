These fixtures are synthetic and contain no user images or location data.

- `oriented-gps.jpg`: a 16 × 8 raster with a red left half and blue right half.
  Its TIFF EXIF specifies orientation 6 (90° clockwise), a dummy camera
  description, and invented GPS coordinates 1°2′3″ N, 4°5′6″ E. The displayed
  image must be 8 × 16, red above blue, after metadata is removed.
- `text-gps.png`: the same unrotated raster with a `tEXt` camera description and
  an `eXIf` chunk containing the synthetic TIFF metadata.
- `wide-animation.gif`: a 2400 × 4 two-frame GIF (red, then blue). It exercises
  animated decoders that ignore target dimensions; the uploaded avatar uses
  the first frame and must still fit within 1200 pixels.
