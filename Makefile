ZG=../zig/zig

.PHONY: all clean build-clean

EXE=zigchess

all: $(EXE)

$(EXE): bot.zig
	$(ZG) build-exe -femit-bin=$@ $^

build-clean:
	rm -f *.o

clean: build-clean
	rm -f $(EXE)