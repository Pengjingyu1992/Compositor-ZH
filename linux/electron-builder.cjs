const { build } = require('../windows/package.json');

module.exports = {
  ...build,
  electronDist: 'node_modules/electron/dist',
  appId: 'org.compositorzh.linux',
  productName: 'Compositor Linux',
  artifactName: 'Compositor-Linux-${version}-${arch}.${ext}',
  directories: { ...build.directories, output: '../linux/release' },
  extraMetadata: {
    name: 'compositor-linux',
    description: 'Compositor / 叠绘 Linux layer editor, built with the Pentrado engine',
    desktopName: 'org.compositorzh.linux.desktop'
  },
  extraResources: build.extraResources.map(resource => resource.from === 'THIRD_PARTY_NOTICES.md'
    ? { ...resource, from: '../linux/THIRD_PARTY_NOTICES.md' } : resource),
  linux: {
    target: ['deb', 'tar.gz'],
    executableName: 'compositor-linux',
    icon: '../Compositor/Assets.xcassets/AppIcon.appiconset/app-icon-512.png',
    category: 'Graphics',
    synopsis: 'Layer painting and image editor',
    maintainer: 'Compositor-ZH contributors <compositor-zh@users.noreply.github.com>',
    syncDesktopName: true,
    desktop: { entry: {
      'Name[zh_CN]': '叠绘 Linux',
      Comment: 'Paint, composite layers and edit .comp projects offline',
      'Comment[zh_CN]': '离线图层绘画、图像合成与 .comp 项目编辑',
      Keywords: 'image;painting;layers;graphics;'
    } }
  },
  deb: {
    depends: ['libgtk-3-0 | libgtk-3-0t64', 'libnss3', 'libxss1', 'libxtst6', 'xdg-utils', 'libatspi2.0-0', 'libuuid1', 'fontconfig', 'libasound2 | libasound2t64', 'libgbm1'],
    recommends: ['libsecret-1-0', 'fonts-noto-cjk']
  }
};
