ZG=../zig/zig

.PHONY: all clean build-clean clean-all

EXE=zigchess

LIBS=-lc

all: $(EXE)

%.o: %.zig
	$(ZG) build-obj $^ $(LIBS)

$(EXE): bot.o luts.o
	$(ZG) build-exe -femit-bin=$@ $^ $(LIBS)

build-clean:
	rm -f bot.o
	rm -f *.o.o

clean: build-clean
	rm -f $(EXE)

clean-all: clean
	rm -f luts.o

