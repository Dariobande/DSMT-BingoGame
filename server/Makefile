# Makefile

.PHONY: all compile clean clean-db ebin clean-all

all: compile

compile: ebin
	erlc -I include/ \
	-pa deps/jsx/ebin \
	-pa deps/cowboy/ebin \
	-pa deps/cowboy/deps/cowlib/ebin \
	-pa deps/cowboy/deps/ranch/ebin \
	-o ebin/ src/*.erl

ebin:
	mkdir -p ebin

clean:
	rm -f ebin/*.beam

clean-db:
	rm -rf Mnesia.*

clean-all: clean clean-db