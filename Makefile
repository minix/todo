zig ?= /data/bin/zig/zig

s:
	${zig} build run -Doptimize=ReleaseFast
	#${zig} build run 

