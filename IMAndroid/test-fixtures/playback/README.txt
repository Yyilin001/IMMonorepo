自制播放测试素材，不包含外部版权内容。

生成命令（FFmpeg）：
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=16000:duration=8' -c:a pcm_s16le tone.wav
ffmpeg -f lavfi -i 'testsrc2=duration=8:size=320x180:rate=12' -f lavfi -i 'sine=frequency=330:sample_rate=44100:duration=8' -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 30 -c:a aac -b:a 48k -movflags +faststart sample.mp4

两者均为 8 秒。音频为单声道 PCM16 WAV；视频为 320×180、12 fps 的 AVC/AAC MP4。
仅在 androidTest 中打包；测试播放器静音。用于应用实际解码及隔离后端的上传、接收、授权原件校验。
