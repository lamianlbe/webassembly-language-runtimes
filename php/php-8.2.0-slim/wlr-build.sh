#!/usr/bin/env bash
logStatus "Building libs 'php/php-8.2.0-slim'"

if [[ ! -v WLR_ENV ]]
then
    echo "WLR build environment is not set"
    exit 1
fi

export CFLAGS_CONFIG="-O2"

########## Setup the wasi related flags #############
export CFLAGS_WASI="--sysroot=${WASI_SYSROOT} -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS"
export LDFLAGS_WASI="--sysroot=${WASI_SYSROOT} -lwasi-emulated-getpid -lwasi-emulated-signal -lwasi-emulated-process-clocks"

########## Setup the flags for php #############
export CFLAGS_PHP='-D_POSIX_SOURCE=1 -D_GNU_SOURCE=1 -DHAVE_FORK=0 -DWASM_WASI'

export LDFLAGS_WARNINGS='-Wno-unused-command-line-argument -Werror=implicit-function-declaration -Wno-incompatible-function-pointer-types'

# We need to add LDFLAGS ot CFLAGS because autoconf compiles(+links) to binary when checking stuff
export LDFLAGS="${LDFLAGS_WASI} ${LDFLAGS_DEPENDENCIES} ${LDFLAGS_SQLITE} ${LDFLAGS_WARNINGS}"
export CFLAGS="${CFLAGS_CONFIG} ${CFLAGS_WASI} ${CFLAGS_DEPENDENCIES} ${CFLAGS_PHP} ${LDFLAGS}"

logStatus "CFLAGS="${CFLAGS}
logStatus "LDFLAGS="${LDFLAGS}


cd "${WLR_SOURCE_PATH}"

if [[ -z "$WLR_SKIP_CONFIGURE" ]]; then
    logStatus "Generating configure script..."
    ./buildconf --force || exit 1

    export PHP_CONFIGURE=''
    PHP_CONFIGURE+=' --disable-all'
    PHP_CONFIGURE+=' --without-libxml'
    PHP_CONFIGURE+=' --disable-dom'
    PHP_CONFIGURE+=' --without-iconv'
    PHP_CONFIGURE+=' --without-openssl'
    PHP_CONFIGURE+=' --disable-simplexml'
    PHP_CONFIGURE+=' --disable-xml'
    PHP_CONFIGURE+=' --disable-xmlreader'
    PHP_CONFIGURE+=' --disable-xmlwriter'
    PHP_CONFIGURE+=' --without-pear'
    PHP_CONFIGURE+=' --disable-phar'
    PHP_CONFIGURE+=' --disable-opcache'
    PHP_CONFIGURE+=' --disable-zend-signals'
    PHP_CONFIGURE+=' --without-pcre-jit'
    PHP_CONFIGURE+=' --without-sqlite3'
    PHP_CONFIGURE+=' --disable-pdo'
    PHP_CONFIGURE+=' --without-pdo-sqlite'
    PHP_CONFIGURE+=' --disable-fiber-asm'

    if [[ -v WLR_RUNTIME ]]
    then
        export PHP_CONFIGURE="--with-wasm-runtime=${WLR_RUNTIME} ${PHP_CONFIGURE}"
    fi

    logStatus "Configuring build with '${PHP_CONFIGURE}'..."
    ./configure --host=wasm32-wasi host_alias=wasm32-musl-wasi --target=wasm32-wasi target_alias=wasm32-musl-wasi ${PHP_CONFIGURE} || exit 1
else
    logStatus "Skipping configure..."
fi

export MAKE_TARGETS='cgi'
if [[ "${WLR_RUNTIME}" == "wasmedge" ]]
then
    export MAKE_TARGETS="${MAKE_TARGETS} cli"
fi

logStatus "Building '${MAKE_TARGETS}'..."
# By exporting WLR_SKIP_WASM_OPT envvar during the build, the
# wasm-opt wrapper in the wasm-base image will be a dummy wrapper that
# is effectively a NOP.
#
# This is due to https://github.com/llvm/llvm-project/issues/55781, so
# that we get to choose which optimization passes are executed after
# the artifacts have been built.
export WLR_SKIP_WASM_OPT=1
make -j ${MAKE_TARGETS} || exit 1
unset WLR_SKIP_WASM_OPT

logStatus "Preparing artifacts..."
mkdir -p ${WLR_OUTPUT}/bin 2>/dev/null || exit 1

logStatus "Running wasm-opt with the asyncify pass on php-cgi..."
wasm-opt -O2 --asyncify --pass-arg=asyncify-ignore-imports -o ${WLR_OUTPUT}/bin/php-cgi${WLR_RUNTIME:+-$WLR_RUNTIME}-slim.wasm sapi/cgi/php-cgi || exit 1

if [[ "${WLR_RUNTIME}" == "wasmedge" ]]
then
    logStatus "Running wasm-opt with the asyncify pass on php..."
    wasm-opt -O2 --asyncify --pass-arg=asyncify-ignore-imports -o ${WLR_OUTPUT}/bin/php${WLR_RUNTIME:+-$WLR_RUNTIME}-slim.wasm sapi/cli/php || exit 1
fi

logStatus "DONE. Artifacts in ${WLR_OUTPUT}"
