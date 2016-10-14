{ stdenv, fetchurl
, bzip2
, gdbm
, fetchpatch
, ncurses
, openssl
, readline
, sqlite
, tcl ? null, tk ? null, xlibsWrapper ? null, libX11 ? null, x11Support ? !stdenv.isCygwin
, zlib
, callPackage
, self
, python27Packages
, gettext
, db
, expat
, libffi
, CF, configd
}:

assert x11Support -> tcl != null
                  && tk != null
                  && xlibsWrapper != null
                  && libX11 != null;

with stdenv.lib;

let
  majorVersion = "2.7";
  minorVersion = "12";
  minorVersionSuffix = "";
  pythonVersion = majorVersion;
  version = "${majorVersion}.${minorVersion}${minorVersionSuffix}";
  libPrefix = "python${majorVersion}";
  sitePackages = "lib/${libPrefix}/site-packages";

  src = fetchurl {
    url = "https://www.python.org/ftp/python/${majorVersion}.${minorVersion}/Python-${version}.tar.xz";
    sha256 = "0y7rl603vmwlxm6ilkhc51rx2mfj14ckcz40xxgs0ljnvlhp30yp";
  };

  patches =
    [ # Look in C_INCLUDE_PATH and LIBRARY_PATH for stuff.
      ./search-path.patch

      # Python recompiles a Python if the mtime stored *in* the
      # pyc/pyo file differs from the mtime of the source file.  This
      # doesn't work in Nix because Nix changes the mtime of files in
      # the Nix store to 1.  So treat that as a special case.
      ./nix-store-mtime.patch

      # patch python to put zero timestamp into pyc
      # if DETERMINISTIC_BUILD env var is set
      ./deterministic-build.patch

      ./properly-detect-curses.patch

      # FIXME: get rid of this after the next release, when the commit referenced here makes
      # it in. We need it until then because it breaks compilation of programs that use
      # locale with clang 3.8 and higher.
      (fetchpatch {
        url    = "https://hg.python.org/cpython/raw-rev/e0ec3471cb09";
        sha256 = "1jdgb70jw942r4kmr01qll7mk1di8jx0qiabmp20jhnmha246ivq";
      })
    ] ++ optionals stdenv.isLinux [

      # Disable the use of ldconfig in ctypes.util.find_library (since
      # ldconfig doesn't work on NixOS), and don't use
      # ctypes.util.find_library during the loading of the uuid module
      # (since it will do a futile invocation of gcc (!) to find
      # libuuid, slowing down program startup a lot).
      ./no-ldconfig.patch

    ] ++ optionals stdenv.isCygwin [
      ./2.5.2-ctypes-util-find_library.patch
      ./2.5.2-tkinter-x11.patch
      ./2.6.2-ssl-threads.patch
      ./2.6.5-export-PySignal_SetWakeupFd.patch
      ./2.6.5-FD_SETSIZE.patch
      ./2.6.5-ncurses-abi6.patch
      ./2.7.3-dbm.patch
      ./2.7.3-dylib.patch
      ./2.7.3-getpath-exe-extension.patch
      ./2.7.3-no-libm.patch
    ];

  preConfigure = ''
      # Purity.
      for i in /usr /sw /opt /pkg; do
        substituteInPlace ./setup.py --replace $i /no-such-path
      done
    '' + optionalString (stdenv ? cc && stdenv.cc.libc != null) ''
      for i in Lib/plat-*/regen; do
        substituteInPlace $i --replace /usr/include/ ${stdenv.cc.libc}/include/
      done
    '' + optionalString stdenv.isDarwin ''
      substituteInPlace configure --replace '`/usr/bin/arch`' '"i386"'
      substituteInPlace Lib/multiprocessing/__init__.py \
        --replace 'os.popen(comm)' 'os.popen("nproc")'
    '';

  configureFlags = [
    "--enable-shared"
    "--with-threads"
    "--enable-unicode=ucs4"
  ] ++ optionals stdenv.isCygwin [
    "--with-system-ffi"
    "--with-system-expat"
    "ac_cv_func_bind_textdomain_codeset=yes"
  ] ++ optionals stdenv.isDarwin [
    "--disable-toolbox-glue"
  ];

  postConfigure = if stdenv.isCygwin then ''
    sed -i Makefile -e 's,PYTHONPATH="$(srcdir),PYTHONPATH="$(abs_srcdir),'
  '' else null;

  buildInputs =
    optional (stdenv ? cc && stdenv.cc.libc != null) stdenv.cc.libc ++
    [ bzip2 openssl zlib ]
    ++ optionals stdenv.isCygwin [ expat libffi ]
    ++ [ db gdbm ncurses sqlite readline ]
    ++ optionals x11Support [ tcl tk xlibsWrapper libX11 ]
    ++ optionals stdenv.isDarwin [ CF configd ];

  mkPaths = paths: {
    C_INCLUDE_PATH = makeSearchPathOutput "dev" "include" paths;
    LIBRARY_PATH = makeLibraryPath paths;
  };

  # Build the basic Python interpreter without modules that have
  # external dependencies.

in stdenv.mkDerivation {
    name = "python-${version}";
    pythonVersion = majorVersion;

    inherit majorVersion version src patches buildInputs
            preConfigure configureFlags;

    LDFLAGS = stdenv.lib.optionalString (!stdenv.isDarwin) "-lgcc_s";
    inherit (mkPaths buildInputs) C_INCLUDE_PATH LIBRARY_PATH;

    NIX_CFLAGS_COMPILE = optionalString stdenv.isDarwin "-msse2";
    DETERMINISTIC_BUILD = 1;

    setupHook = ./setup-hook.sh;

    postInstall =
      ''
        # needed for some packages, especially packages that backport
        # functionality to 2.x from 3.x
        for item in $out/lib/python${majorVersion}/test/*; do
          if [[ "$item" != */test_support.py* ]]; then
            rm -rf "$item"
          else
            echo $item
          fi
        done
        touch $out/lib/python${majorVersion}/test/__init__.py
        ln -s $out/lib/python${majorVersion}/pdb.py $out/bin/pdb
        ln -s $out/lib/python${majorVersion}/pdb.py $out/bin/pdb${majorVersion}
        ln -s $out/share/man/man1/{python2.7.1.gz,python.1.gz}

        paxmark E $out/bin/python${majorVersion}

        # Python on Nix is not manylinux1 compatible. https://github.com/NixOS/nixpkgs/issues/18484
        echo "manylinux1_compatible=False" >> $out/lib/${libPrefix}/_manylinux.py

        rm "$out"/lib/python*/plat-*/regen # refers to glibc.dev
      '';

    postFixup = optionalString x11Support ''
      # tkinter goes in a separate output
      mkdir -p $tkinter/${sitePackages}
      mv $out/lib/${libPrefix}/lib-dynload/_tkinter* $tkinter/${sitePackages}/
    '';

    outputs = ["out"] ++ optional x11Support "tkinter";

    passthru = rec {
      inherit libPrefix sitePackages x11Support;
      executable = libPrefix;
      buildEnv = callPackage ../../wrapper.nix { python = self; };
      withPackages = import ../../with-packages.nix { inherit buildEnv; pythonPackages = python27Packages; };
      isPy2 = true;
      isPy27 = true;
      interpreter = "${self}/bin/${executable}";
    };

    enableParallelBuilding = true;

    meta = {
      homepage = "http://python.org";
      description = "A high-level dynamically-typed programming language";
      longDescription = ''
        Python is a remarkably powerful dynamic programming language that
        is used in a wide variety of application domains. Some of its key
        distinguishing features include: clear, readable syntax; strong
        introspection capabilities; intuitive object orientation; natural
        expression of procedural code; full modularity, supporting
        hierarchical packages; exception-based error handling; and very
        high level dynamic data types.
      '';
      license = stdenv.lib.licenses.psfl;
      platforms = stdenv.lib.platforms.all;
      maintainers = with stdenv.lib.maintainers; [ chaoflow domenkozar ];
    };
  }
