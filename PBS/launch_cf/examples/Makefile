# Makefile for the launch_cf examples.
#
#   make             build hello_omp.exe and generate the example command files
#   make cmdfiles    (re)generate the example command files only
#   make submit      submit the derecho-640procs example with launch_cf
#   make dryrun      show what that submission would request, without submitting
#   make csv         summarize a finished run into derecho-640procs/steps.csv
#   make clean       remove build products
#   make clobber     also remove job output from previous runs
#
# The compiler defaults to the Cray wrapper, which is what Derecho provides.
# Override on the command line if you need to, e.g.
#   make CXX=g++
#   make OMPFLAGS=-qopenmp     # Intel classic compilers

CXX      ?= CC
CXXFLAGS ?= -O2
OMPFLAGS ?= -fopenmp
PYTHON   ?= python3

launch_cf ?= ../../launch_cf

# Each example directory holds its own cmdfile and submission script.
EXAMPLES := derecho-640procs
CMDFILES := $(addsuffix /cmdfile,$(EXAMPLES))

all: hello_omp.exe $(CMDFILES)

hello_omp.exe: hello_omp.cpp
	$(CXX) $(CXXFLAGS) $(OMPFLAGS) -o $@ $<

cmdfiles: $(CMDFILES)

# 640 steps: with the Derecho defaults (ppn=128, nthreads=1) this is
# 128 steps/node -> a 5-element job array -> 5 nodes.
# Add further examples by copying this rule with a different step count.
derecho-640procs/cmdfile: gen_cmdfile.sh Makefile
	./gen_cmdfile.sh --nsteps 640 --exe ../hello_omp.exe --output $@

submit: all
	cd derecho-640procs && ./submit_launch_cf.sh

# Same job, generated and described but not queued.  Requires launch_cf to be
# in your PATH, or override e.g. "make dryrun launch_cf=/path/to/launch_cf".
dryrun: all
	cd derecho-640procs && $(launch_cf) -A $${PBS_ACCOUNT} -l walltime=00:10:00 --dryrun ./cmdfile

# Collect the per-step output of the most recent run.  Override the run with
# "make csv RUNDIR=derecho-640procs/stdout-1234567"
RUNDIR ?= $(firstword $(shell ls -dt derecho-640procs/stdout-* 2>/dev/null))

csv:
	@test -n "$(RUNDIR)" || { echo "ERROR: no derecho-640procs/stdout-* directory found; run \"make submit\" first"; exit 1; }
	$(PYTHON) ./parse_steps.py $(RUNDIR) \
	  --lscpu derecho-640procs/lscpu.txt \
	  -o derecho-640procs/steps.csv

clean:
	rm -f hello_omp.exe *.o *~

clobber: clean
	rm -rf $(addsuffix /stdout-*,$(EXAMPLES))
	rm -f $(addsuffix /steps.csv,$(EXAMPLES))
	rm -f $(addsuffix /launch_cf.log,$(EXAMPLES))
	rm -f $(addsuffix /launch_cf.*.pbs,$(EXAMPLES))
	rm -f $(addsuffix /launch_cf.o*,$(EXAMPLES))

.PHONY: all cmdfiles submit dryrun csv clean clobber
