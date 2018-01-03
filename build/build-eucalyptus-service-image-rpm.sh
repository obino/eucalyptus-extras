#!/bin/bash
# Build eucalyptus service image rpm on CentOS/RHEL 7
#
# Builds using dependency rpms from:
# http://downloads.eucalyptus.com/software/eucalyptus/4.4/rhel/7Server/x86_64/
#
# To build using git snapshot rpms copy to EUCALYPTUS_BUILD_REPO_DIR
# and they will be included in repository (or build using predefined
# RPMBUILD)
#
# If building on an instance ensure cpu passthrough is enabled:
#   cat /sys/module/kvm_intel/parameters/nested
#   USE_CPU_PASSTHROUGH="1"

# config
MODE="${1:-build}" # setup build build-only
YUM_OPTS="${YUM_OPTS:--y}"
EUCA_SIM_BRANCH="${EUCA_SIM_BRANCH:-maint-3}"
EUCA_SIM_REPO="${EUCA_SIM_REPO:-https://github.com/sjones4/eucalyptus-service-image.git}"
EUCALYPTUS_BUILD_REPO_DIR="${EUCALYPTUS_BUILD_REPO_DIR:-""}"
EUCALYPTUS_BUILD_REPO_IP=${EUCALYPTUS_BUILD_REPO_IP:-""}
EUCALYPTUS_MIRROR="${EUCALYPTUS_MIRROR:-http://downloads.eucalyptus.com/software/eucalyptus/4.4/rhel/7/x86_64/}"
EUCA2OOLS_MIRROR="${EUCA2OOLS_MIRROR:-http://downloads.eucalyptus.com/software/euca2ools/3.3/rhel/7/x86_64/}"
REQUIRE=(
    "autoconf"
    "createrepo"
    "git"
    "httpd"
    "libguestfs-tools-c" # for virt-sparsify virt-sysprep
    "libvirt-daemon-config-network"
    "make"
    "python-devel"
    "python-prettytable"
    "rpm-build"
    "rpmdevtools" # for spectool
    "virt-install"
    "yum-utils"
)
set -ex

# dependencies
if [ "${MODE}" != "build-only" ] ; then
  rm -rf /var/www/eucalyptus-packages.??????????

  yum ${YUM_OPTS} erase 'eucalyptus-*' 'load-balancer-servo'

  yum ${YUM_OPTS} install "${REQUIRE[@]}"
fi

[ "${MODE}" != "setup" ] || exit 0

#
if [ -z "${EUCALYPTUS_BUILD_REPO_IP}" ] ; then
  EUCALYPTUS_BUILD_REPO_IP=$(curl "http://169.254.169.254/latest/meta-data/local-ipv4")
  [ ! -z "${EUCALYPTUS_BUILD_REPO_IP}" ] || ( echo "Could not detect ip" && exit 1 )
fi
if [ -z "${EUCALYPTUS_BUILD_REPO_DIR}" ] ; then
  EUCALYPTUS_BUILD_REPO_DIR=$(mktemp -td --tmpdir="/var/www/" "eucalyptus-packages.XXXXXXXXXX")
  chmod 755 "${EUCALYPTUS_BUILD_REPO_DIR}"
fi

# clone repositories
if [ "${MODE}" != "build-only" ] ; then
  [ ! -d "eucalyptus-service-image" ] || rm -rf "eucalyptus-service-image"
  git clone --depth 1 --branch "${EUCA_SIM_BRANCH}" "${EUCA_SIM_REPO}"
fi

# setup rpmbuild
RPMBUILD=${RPMBUILD:-$(mktemp -td "rpmbuild.XXXXXXXXXX")}
mkdir -p "${RPMBUILD}/SPECS"
mkdir -p "${RPMBUILD}/SOURCES"

[ ! -f "${RPMBUILD}/SPECS/eucalyptus-service-image.spec" ] || rm -f \
  "${RPMBUILD}/SPECS/eucalyptus-service-image.spec"
ln -fs "$(pwd)/eucalyptus-service-image/eucalyptus-service-image.spec" \
  "${RPMBUILD}/SPECS"

# get commit info
pushd "eucalyptus-service-image"
EUCA_SIM_GIT_SHORT=$(git rev-parse --short HEAD)
EUCA_SIM_VERSION=$(spectool -l "eucalyptus-service-image.spec" | grep -oP 'eucalyptus-service-image-\K[.0-9]*(?=.tar.xz)')
autoconf
popd

# generate source tars
tar -cvJf "${RPMBUILD}/SOURCES/eucalyptus-service-image-${EUCA_SIM_VERSION}.tar.xz" \
    --transform "s|^eucalyptus-service-image|eucalyptus-service-image-${EUCA_SIM_VERSION}|" \
    --exclude ".git*" \
    --exclude "eucalyptus-service-image.spec" \
    "eucalyptus-service-image"

# build rpms
RPMBUILD_OPTS="${RPMBUILD_OPTS}"
RPM_DIST="${RPM_DIST:-el7}"
RPM_VERSION="${RPM_VERSION:-$(date -u +%Y%m%d%H%M)}"
RPM_BUILD_ID="${RPM_BUILD_ID:-${RPM_VERSION}git${EUCA_SIM_GIT_SHORT}}"

# build local repository for use in service image build
mkdir -p "${EUCALYPTUS_BUILD_REPO_DIR}"

EUCALYPTUS_BUILD_REPO_YUM_CONF=$(mktemp -t "yum.conf.XXXXXXXXXX")
cat > "${EUCALYPTUS_BUILD_REPO_YUM_CONF}" << HERE
[localeuca]
name=localeuca
baseurl=file://${EUCALYPTUS_BUILD_REPO_DIR}
enabled=1

[mirroreuca]
name=mirroreuca
baseurl=${EUCALYPTUS_MIRROR}
enabled=1
HERE

cp -v "${RPMBUILD}/RPMS"/*/*.rpm "${EUCALYPTUS_BUILD_REPO_DIR}"

createrepo "${EUCALYPTUS_BUILD_REPO_DIR}"

yumdownloader \
  --assumeyes \
  --resolve \
  --config="${EUCALYPTUS_BUILD_REPO_YUM_CONF}" \
  --exclude=euca2ools \
  --destdir "${EUCALYPTUS_BUILD_REPO_DIR}" \
  eucalyptus-imaging-worker load-balancer-servo ec2-net-utils

rm -rf "${EUCALYPTUS_BUILD_REPO_DIR}/repodata"
yum \
  --config="${EUCALYPTUS_BUILD_REPO_YUM_CONF}" \
  --disablerepo=* \
  --enablerepo=localeuca \
  clean all

createrepo "${EUCALYPTUS_BUILD_REPO_DIR}"

cat > "/etc/httpd/conf.d/eucalyptus-local-packages.conf" << HERE
Alias /eucalyptus-local-packages "${EUCALYPTUS_BUILD_REPO_DIR}"

<Directory "${EUCALYPTUS_BUILD_REPO_DIR}">
    SetEnv VIRTUALENV
    Options MultiViews Indexes
    Order allow,deny
    Allow from all
</Directory>

HERE

systemctl restart httpd

echo "EUCALYPTUS_MIRROR=http://${EUCALYPTUS_BUILD_REPO_IP}/eucalyptus-local-packages/"

systemctl start libvirtd

chmod 770 "${RPMBUILD}"
chgrp qemu "${RPMBUILD}"
export DISK=2       # override make defined DISK=2
export MEMORY=2048  # override make defined MEMORY=1024
export EUCA_SIM_CONFIGURE_OPTS="
  --with-eucalyptus-mirror=http://${EUCALYPTUS_BUILD_REPO_IP}/eucalyptus-local-packages/
  --with-euca2ools-mirror=${EUCA2OOLS_MIRROR}
"

rpmbuild \
    --define "_topdir ${RPMBUILD}" \
    --define "dist .${RPM_BUILD_ID}.${RPM_DIST}" \
    --define "configure_opts ${EUCA_SIM_CONFIGURE_OPTS//$'\n'/ }" \
    ${RPMBUILD_OPTS} \
    -ba "${RPMBUILD}/SPECS/eucalyptus-service-image.spec"

systemctl stop libvirtd

[ ! -f "${EUCALYPTUS_BUILD_REPO_YUM_CONF}" ] || \
  rm -fv "${EUCALYPTUS_BUILD_REPO_YUM_CONF}"

find "${RPMBUILD}/SRPMS/"

find "${RPMBUILD}/RPMS/"

if [ ! -z "${RPM_OUT}" ] && [ -d "${RPM_OUT}" ] ; then
    cp -pv "${RPMBUILD}/RPMS"/*/*.rpm "${RPM_OUT}"
fi

echo "Build complete"
