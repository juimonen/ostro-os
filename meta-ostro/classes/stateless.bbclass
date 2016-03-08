# This moves files out of /etc. It gets applied both
# to individual packages (to avoid or at least catch problems
# early) as well as the entire rootfs (to catch files not
# contained in packages).

def stateless_is_whitelisted(etcentry, whitelist):
    import fnmatch
    for pattern in whitelist:
        if fnmatch.fnmatchcase(etcentry, pattern):
            return True
    return False

def stateless_mangle(d, root, docdir, stateless_mv, stateless_rm, dirwhitelist, is_package):
    import os
    import errno

    # Move away files. Default target is docdir, but others can
    # be set by appending =<new name> to the entry, as in
    # tmpfiles.d=libdir/tmpfiles.d
    for entry in stateless_mv:
        paths = entry.split('=', 1)
        etcentry = paths[0]
        old = os.path.join(root, 'etc', etcentry)
        if os.path.exists(old) or os.path.islink(old):
            if len(paths) > 1:
                new = root + paths[1]
            else:
                new = os.path.join(docdir, entry)
            destdir = os.path.dirname(new)
            bb.utils.mkdirhier(destdir)
            # Also handles moving of directories where the target already exists, by
            # moving the content. When moving a relative symlink the target gets updated.
            def move(old, new):
                bb.note('stateless: moving %s to %s' % (old, new))
                if os.path.isdir(new):
                    for entry in os.listdir(old):
                        move(os.path.join(old, entry), os.path.join(new, entry))
                    os.rmdir(old)
                else:
                    os.rename(old, new)
            move(old, new)

    # Remove content that is no longer needed.
    for entry in stateless_rm:
        old = os.path.join(root, 'etc', entry)
        if os.path.exists(old) or os.path.islink(old):
            bb.note('stateless: removing %s' % old)
            os.unlink(old)

    # Remove /etc if all that's left are directories.
    # Some directories are expected to exists (for example,
    # update-ca-certificates depends on /etc/ssl/certs),
    # so if a directory is white-listed, it does not get
    # removed.
    etcdir = os.path.join(root, 'etc')
    def tryrmdir(path):
        if is_package and \
           path.endswith('/etc/modprobe.d') or \
           path.endswith('/etc/modules-load.d'):
           # Expected to exist by kernel-module-split.bbclass
           # which will clean it itself.
           return
        if stateless_is_whitelisted(path[len(etcdir) + 1:], dirwhitelist):
           bb.note('stateless: keeping white-listed directory %s' % path)
           return
        bb.note('stateless: removing dir %s' % path)
        try:
            os.rmdir(path)
        except OSError, ex:
            bb.note('stateless: removing dir failed: %s' % ex)
            if ex.errno != errno.ENOTEMPTY:
                 raise
    if os.path.isdir(etcdir):
        for root, dirs, files in os.walk(etcdir, topdown=False):
            for dir in dirs:
                path = os.path.join(root, dir)
                if os.path.islink(path):
                    files.append(dir)
                else:
                    tryrmdir(path)
            for file in files:
                bb.note('stateless: /etc not empty: %s' % os.path.join(root, file))
        tryrmdir(etcdir)


# Modify ${D} after do_install and before do_package resp. do_populate_sysroot.
do_install[postfuncs] += "stateless_mangle_package"
python stateless_mangle_package() {
    pn = d.getVar('PN', True)
    if pn in (d.getVar('STATELESS_PN_WHITELIST', True) or '').split():
        return
    installdir = d.getVar('D', True)
    docdir = installdir + os.path.join(d.getVar('docdir', True), pn, 'etc')
    whitelist = (d.getVar('STATELESS_ETC_DIR_WHITELIST', True) or '').split()

    stateless_mangle(d, installdir, docdir,
                     (d.getVar('STATELESS_MV', True) or '').split(),
                     (d.getVar('STATELESS_RM', True) or '').split(),
                     whitelist,
                     True)
}

# Check that nothing is left in /etc.
PACKAGEFUNCS += "stateless_check"
python stateless_check() {
    pn = d.getVar('PN', True)
    if pn in (d.getVar('STATELESS_PN_WHITELIST', True) or '').split():
        return
    whitelist = (d.getVar('STATELESS_ETC_WHITELIST', True) or '').split()
    import os
    sane = True
    for pkg, files in pkgfiles.iteritems():
        pkgdir = os.path.join(d.getVar('PKGDEST', True), pkg)
        for file in files:
            targetfile = file[len(pkgdir):]
            if targetfile.startswith('/etc/') and \
               not stateless_is_whitelisted(targetfile[len('/etc/'):], whitelist):
                bb.warn("stateless: %s should not contain %s" % (pkg, file))
                sane = False
    if not sane:
        d.setVar("QA_SANE", "")
}

# TODO: modifying SRC_URI here does not seem to invalidate sstate.
# At least adding or removing patches does not trigger a rebuild.
python () {
    import os
    patchdir = d.expand('${STATELESS_PATCHES_BASE}/${PN}')
    if os.path.isdir(patchdir):
        patches = os.listdir(patchdir)
        if patches:
            filespath = d.getVar('FILESPATH', True)
            d.setVar('FILESPATH', filespath + ':' + patchdir)
            srcuri = d.getVar('SRC_URI', True)
            d.setVar('SRC_URI', srcuri + ' ' + ' '.join(['file://' + x for x in sorted(patches)]))

    relocate = d.getVar('STATELESS_RELOCATE', True)
    if relocate != 'False':
        defaultsdir = d.expand('${datadir}/defaults') if relocate == 'True' else relocate
        d.setVar('sysconfdir', defaultsdir)
        d.setVar('EXTRA_OECONF', d.getVar('EXTRA_OECONF', True) + " --sysconfdir=" + defaultsdir)
}

# Several post-install scripts modify /etc.
# For example:
# /etc/shells - gets extended when installing a shell package
# /etc/passwd - adduser in postinst extends it
# /etc/systemd/system - has several .wants entries
#
# This gets fixed directly after installing packages.
# All further modifications in ROOTFS_POSTPROCESS_COMMAND and
# later then may use /etc again (like setting an empty
# root password in /etc/passwd).
ROOTFS_POSTINSTALL_COMMAND += "stateless_mangle_rootfs;"
python stateless_mangle_rootfs () {
    pn = d.getVar('PN', True)
    if pn in (d.getVar('STATELESS_PN_WHITELIST', True) or '').split():
        return

    rootfsdir = d.getVar('IMAGE_ROOTFS', True)
    docdir = rootfsdir + d.getVar('datadir') + '/doc/etc'
    whitelist = (d.getVar('STATELESS_ETC_WHITELIST', True) or '').split()
    stateless_mangle(d, rootfsdir, docdir,
                     (d.getVar('STATELESS_MV_ROOTFS', True) or '').split(),
                     (d.getVar('STATELESS_RM_ROOTFS', True) or '').split(),
                     whitelist,
                     False)
    import os
    etcdir = os.path.join(rootfsdir, 'etc')
    valid = True
    for dirpath, dirnames, filenames in os.walk(etcdir):
        for entry in filenames + [x for x in dirnames if os.path.islink(x)]:
            fullpath = os.path.join(dirpath, entry)
            etcentry = fullpath[len(etcdir) + 1:]
            if not stateless_is_whitelisted(etcentry, whitelist):
                bb.warn('stateless: rootfs should not contain %s' % fullpath)
                valid = False
    if not valid:
        bb.fatal('stateless: /etc not empty')
}