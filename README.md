# Minic

A compiler for the made-up 'mini' programming language written in Ruby. Targets the armv7-a 32-bit arcitecture.

Update: This no longer works because files I did not author such as the provided parser, tests, and benchmarks have been removed. An overview of the design and implementation is available in the file `paper.pdf`.

## Installation
1. Clone this repo
2. Install ruby 2.3+ (development was done using 2.3.3, but anything 2.3+ should work -- 2.4.4 works fine)

   Use your systems [package manager](https://www.ruby-lang.org/en/documentation/installation/#package-mangement-systems). On CentOS-7, it may be more convenient to build from source (but make sure you have appropriate development-dependencies).

   If you encounter problems when installing gems, see this [post](https://stackoverflow.com/questions/20559255/error-while-installing-json-gem-mkmf-rb-cant-find-header-files-for-ruby/26225468#26225468) to make sure you have right install.

   If all else fails, you can just [build it from source](https://www.ruby-lang.org/en/documentation/installation/#building-from-source). Note that this may require some of the following commands to be run as sudo which will require manual linking.
3. Install ruby-bundler `gem install bundler`

   Make sure you install version 1.16.* (should be the default). If problems arise, ensure that you don't already have a version of bundler install `gem list bundler`, in that case, just uninstall any existing version of ruby/bundler and try again.
4. `cd minic`
5. Install dependendencies with `bundler install` (sudo if ruby install requires it)
6. Ensure that you have a current JDK/JVM installed that supports Java 8+ (can run major version 52+)
7. Add ANTLR dependencies to your CLASSPATH `export CLASSPATH=".:(full/path/to)/minic/bin/antlr-4.7.1-complete.jar:$CLASSPATH"`
8. (optional) add `minic/bin` to your path 
9. (optional) set `$MINIC_PARSER=path/to/parser` in your environment (else you may need to use `-p <path/to/parser>` when compiling

## Usage

The executable `minic` is located in `minic/bin`, either set this in your path or use its path (though you may need to be inside the minic directory)

    $ minic <options> <source files>
 
Note that multiple source files can be included at once and will each be executed in sequence
    
Valid compiler options include:  
```
-oOUTFILE                    resulting assembly file, else will use the name of the input file with a .s suffix
-pPARSEDIR                   directory of the provided Java AST parser (else uses $MINIC_PARSER)
-stack                       Use stack-based llvm IR for code generation
--all                        produce all intermediate files
--type-check[=OUTFILE]       write the typechecked ast in json format to file
--llvm[=OUTFILE]             write the program in llvm form to file
--cfg[=OUTFILE]              write the cfg in dot format to file
--noalloc[=OUTFILE]          write the assembly prior to register allocation
--if-graph[=OUTFILE]         write the interference graph in dot format to file
```

* Note, ommit the OUTFILE from the options to use a default filename based on the input

Example Usage)
```
# Compile source1 and source2 into SSA ARM assembly => source1.s, source2.s
minic source1.mini source2.mini

# Compile and produce the associated LLVM file (can ommit the =file.ll) => file.ll, source.s
mini --llvm=file.ll source.mini

# Compile and produce Stack-based LLVM & ARM => source.ll, source.s
mini --stack --llvm source.mini

# Compile and produce cfg in dot format => source_cfg.dot
minic --cfg source.mini

# Compile and produce interference graph in dot format => source_if_graph.dot
minic --if-graph source.mini

# Compile and produce arm without allocated registers => source_no_alloc.s, source.s
minic --noalloc source.mini

# Compile and produce all intermediate files at once
minic --all source.mini
```

## Debug
* if the compiler complains about being unable to parse JSON, try running the given parser directly on the source file to see if it is producing valid JSON (may be a problem with your Java/ANTLR install)
