ZG=../zig/zig

.PHONY: all clean build-clean clean-all

EXE=zigchess

LIBS=

all: $(EXE)

%.o: %.zig
	$(ZG) build-obj $^

$(EXE): bot.o luts.o
	$(ZG) build-exe -femit-bin=$@ $^ $(LIBS)

build-clean:
	rm -f bot.o
	rm -f *.o.o

clean: build-clean
	rm -f $(EXE)

clean-all: clean
	rm -f luts.o

