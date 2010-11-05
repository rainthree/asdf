system	 	:= "asdf"
#user 		:= $(shell basename `echo "$home"`)
user := "frideau"
webhome_private := $(user)@common-lisp.net:/project/asdf/public_html/
webhome_public	:= "http://common-lisp.net/project/asdf/"
clnet_home      := "/project/asdf/public_html/"

sourceDirectory := $(shell pwd)

lisps ?= ccl clisp sbcl ecl allegro abcl scl
## not tested by me: allegromodern cmucl lisworks
## FAIL: gclcvs
## maybe supported by asdf, not supported yet by our tests: cormancl mcl scl

lisp ?= sbcl

# website, tag, install

install: archive-copy

bump_revision: FORCE
	bin/bump-revision-and-tag.sh

archive: FORCE
	sbcl --userinit /dev/null --sysinit /dev/null --load bin/make-helper.lisp \
		--eval "(rewrite-license)" --eval "(quit)"
	bin/build-tarball.sh

archive-copy: archive
	git checkout release
	bin/rsync-cp.sh tmp/asdf*.tar.gz $(webhome_private)/archives
	bin/link-tarball.sh $(clnet_home) $(user)
	bin/rsync-cp.sh tmp/asdf.lisp $(webhome_private)
	${MAKE} push

push:
	git status
	git push --tags cl.net release master
	git push --tags xcvb release master
	git fetch
	git status

website:
	make -C doc website

clean_dirs = $(sourceDirectory)
clean_extensions = fasl dfsl cfsl fasl fas lib dx32fsl lx64fsl lx32fsl o bak x86f

clean: FORCE
	@for dir in $(clean_dirs); do \
	     if test -d $$dir; then \
	     	 echo Cleaning $$dir; \
		 for ext in $(clean_extensions); do \
		     find $$dir \( -name "*.$$ext" \) \
	     	    -and -not -path \""*/.git/*"\" \
		     	  -and -not -path \""*/_darcs/*"\" \
	     		  -and -not -path \""*/tags/*"\" -print -delete; \
		done; \
	     fi; \
	done
	rm -rf tmp/ LICENSE test/try-reloading-dependency.asd
	make -C doc clean

mrproper: clean
	rm -rf .pc/ build-stamp debian/patches/ debian/debhelper.log debian/cl-asdf/ # debian crap


test: FORCE
	@cd test; make clean;./run-tests.sh ${lisp} ${test-glob}

test-all: FORCE
	@for lisp in ${lisps} ; do \
		make test lisp=$$lisp || exit 1 ; \
	done

debian-package: mrproper
	git-buildpackage --git-debian-branch=release --git-upstream-branch=RELEASE --git-tag --git-retag

# Replace SBCL's ASDF with the current one.
# not recommended: just use (asdf:load-system :asdf)
replace-sbcl-asdf:
	sbcl --eval '(compile-file "asdf.lisp" :output-file (format nil "~Aasdf/asdf.fasl" (sb-int:sbcl-homedir-pathname)))' --eval '(quit)'

# Replace CCL's ASDF with the current one.
# not recommended: just use (asdf:load-system :asdf)
replace-ccl-asdf:
	ccl --eval '(progn(compile-file "asdf.lisp" :output-file (format nil "~Atools/asdf.lx64fsl" (ccl::ccl-directory)))(quit))'

FORCE:
