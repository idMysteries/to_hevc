# to_hevc (supports AMD, NVIDIA and Intel encoders)
Powershell script is for converting video to HEVC via ffmpeg with a bitrate reduction of about 40%


## usage
```
All videos:
to_hevc

Specific videos:
to_hevc video1 video2 ...

Set crf (qp_i, qp_p) to 18 and do not remove the original file
to_hevc -qp 18 -Save
```
