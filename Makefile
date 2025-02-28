ZG=../zig/zig

.PHONY: all clean build-clean clean-all

EXE=zigchess

LIBS=-lc $(shell curl-config --libs)

all: $(EXE)

main.o: main.zig defs.zig lichess.zig bot.zig
	$(ZG) build-obj $< $(LIBS)

luts.o: luts.zig
	$(ZG) build-obj $^ $(LIBS)

$(EXE): main.o luts.o
	$(ZG) build-exe -femit-bin=$@ $^ $(LIBS)

build-clean:
	rm -f main.o
	rm -f *.o.o

clean: build-clean
	rm -f $(EXE)

clean-all: clean
	rm -f luts.o

