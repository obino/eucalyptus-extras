#!/bin/bash
# Build eucaconsole rpm on CentOS/RHEL 7

# config
MODE="${1:-build}" # setup build build-only
VERSION="4.4"
EUCA_CON_BRANCH="devel-${VERSION}"
EUCA_CON_REPO="https://github.com/sjones4/eucaconsole.git"
REQUIRE=(
    "git"
    "yum-utils"
    "wget"
    "m2crypto"
    "openssl-devel"
    "pycryptopp"
    "python-chameleon"
    "python-dateutil"
    "python-devel"
    "python-eventlet"
    "python-greenlet"
    "python-gunicorn"
    "python-lxml"
    "python-nose"
    "python-pygments"
    "python-pyramid"
    "python-simplejson"
    "python-wtforms"
    "python2-boto"
    "rpmdevtools" # for spectool
)
REQUIRE_EUCA=(
    "http://downloads.eucalyptus.com/software/eucalyptus/4.4/rhel/7Server/x86_64/python-pylibmc-1.2.3-6.1.el7.x86_64.rpm"
    "http://downloads.eucalyptus.com/software/eucalyptus/4.4/rhel/7Server/x86_64/python-pylibmc-debuginfo-1.2.3-6.1.el7.x86_64.rpm"
)
set -ex

# dependencies
if [ "${MODE}" != "build-only" ] ; then
  yum erase -y 'eucaconsole-*'

  yum install -y "epel-release"

  yum -y install "${REQUIRE[@]}"

  yum -y groupinstall "development"

  yum -y install "${REQUIRE_EUCA[@]}" || yum -y upgrade "${REQUIRE_EUCA[@]}"
fi

[ "${MODE}" != "setup" ] || exit 0

# clone repositories
if [ "${MODE}" != "build-only" ] ; then
  [ ! -d "eucaconsole" ] || rm -rf "eucaconsole"
  git clone --depth 1 --branch "${EUCA_CON_BRANCH}" "${EUCA_CON_REPO}"
fi

# setup rpmbuild
RPMBUILD=${RPMBUILD:-$(mktemp -td "rpmbuild.XXXXXXXXXX")}
mkdir -p "${RPMBUILD}/SPECS"
mkdir -p "${RPMBUILD}/SOURCES"

[ ! -f "${RPMBUILD}/SPECS/eucaconsole.spec" ] || rm -f \
  "${RPMBUILD}/SPECS/eucaconsole.spec"
ln -fs "$(pwd)/eucaconsole/rpmspec/eucaconsole.spec" \
  "${RPMBUILD}/SPECS"

# generate source tars, get commit info
pushd "eucaconsole"
EUCA_CON_GIT_SHORT=$(git rev-parse --short HEAD)
popd
tar -cvJf "${RPMBUILD}/SOURCES/eucaconsole.tar.xz" \
    --exclude ".git*" \
    "eucaconsole"

for EUCA_CON_SOURCE in $(spectool -l "eucaconsole/rpmspec/eucaconsole.spec" | awk '{print $2}' | grep -v '%')
do
  cp "eucaconsole/rpmspec/${EUCA_CON_SOURCE}" "${RPMBUILD}/SOURCES/"
done

# build rpms
RPMBUILD_OPTS="${RPMBUILD_OPTS}"
RPM_DIST="${RPM_DIST:-el7}"
RPM_VERSION="$(date -u +%Y%m%d)git"
RPM_BUILD_ID="${RPM_BUILD_ID:-${RPM_VERSION}${EUCA_CON_GIT_SHORT}}"

rpmbuild \
    --define "_topdir ${RPMBUILD}" \
    --define 'tarball_basedir eucaconsole' \
    --define "dist ${RPM_DIST}" \
    --define "build_id ${RPM_BUILD_ID}." \
    ${RPMBUILD_OPTS} \
    -ba "${RPMBUILD}/SPECS/eucaconsole.spec"

find "${RPMBUILD}/SRPMS/"

find "${RPMBUILD}/RPMS/"

if [ ! -z "${RPM_OUT}" ] && [ -d "${RPM_OUT}" ] ; then
    cp -pv "${RPMBUILD}/RPMS"/*/*.rpm "${RPM_OUT}"
fi

echo "Build complete"

