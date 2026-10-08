#!/usr/bin/env ruby
require 'xcodeproj'

root = File.expand_path('..', __dir__)
Dir.chdir(root)
project = Xcodeproj::Project.new('CodexUsageViewer.xcodeproj')
project.root_object.attributes['LastUpgradeCheck'] = '2700'
project.build_configurations.each do |config|
  config.build_settings.merge!({
    'MACOSX_DEPLOYMENT_TARGET' => '27.0',
    'SWIFT_VERSION' => '5.0',
    'CLANG_ENABLE_MODULES' => 'YES',
    'SWIFT_STRICT_CONCURRENCY' => 'complete',
    'DEVELOPMENT_TEAM' => ENV.fetch('CUV_DEVELOPMENT_TEAM', 'AW7ZNT442J'),
    'CODE_SIGN_STYLE' => 'Manual',
    'CODE_SIGN_IDENTITY' => ENV.fetch('CUV_SIGNING_IDENTITY', 'Developer ID Application'),
    'ENABLE_HARDENED_RUNTIME' => 'YES',
    'MARKETING_VERSION' => File.read('VERSION').strip,
    'CURRENT_PROJECT_VERSION' => '1',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
    'SWIFT_EMIT_LOC_STRINGS' => 'YES'
  })
  if config.name == 'Release'
    config.build_settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] = 'NO'
    config.build_settings['OTHER_CODE_SIGN_FLAGS'] = '--timestamp'
  end
end
app = project.new_target(:application, 'CodexUsageViewer', :osx, '27.0')
widget = project.new_target(:app_extension, 'CodexUsageViewerWidget', :osx, '27.0')
helper = project.new_target(:command_line_tool, 'CodexUsageViewerHelper', :osx, '27.0')
groups = {}
%w[CodexUsageViewer Shared Background CodexUsageViewerHelper CodexUsageViewerWidget Config Tests].each { |name| groups[name] = project.main_group.new_group(name, name) }
refs = {}
Dir.glob('{CodexUsageViewer,Shared,Background,CodexUsageViewerHelper,CodexUsageViewerWidget}/**/*.swift').sort.each do |path|
  top, rest = path.split('/', 2)
  refs[path] = groups[top].new_file(rest)
end
refs.each do |path, ref|
  app.source_build_phase.add_file_reference(ref) if path.start_with?('CodexUsageViewer/', 'Shared/', 'Background/')
  widget.source_build_phase.add_file_reference(ref) if path.start_with?('CodexUsageViewerWidget/', 'Shared/')
  if path.start_with?('CodexUsageViewerHelper/', 'Background/', 'Shared/', 'CodexUsageViewer/Services/') || path == 'CodexUsageViewer/CodexUsageViewerStore.swift'
    helper.source_build_phase.add_file_reference(ref)
  end
end
Dir.glob('Config/*').sort.each { |path| refs[path] = groups['Config'].new_file(File.basename(path)) }
if Dir.exist?('CodexUsageViewer/Assets.xcassets')
  app.resources_build_phase.add_file_reference(groups['CodexUsageViewer'].new_file('Assets.xcassets'))
end
[app, widget].each do |target|
  version_phase = target.new_shell_script_build_phase('Derive version from Git')
  version_phase.shell_script = 'python3 "${SRCROOT}/scripts/version.py" --write-bundle "${TARGET_BUILD_DIR}/${WRAPPER_NAME}"'
  version_phase.input_paths = ['$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)']
  version_phase.output_paths = ['$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/BuildVersion.json']
  version_phase.always_out_of_date = '1'
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => target == app ? 'com.inndevs.codexusageviewer' : 'com.inndevs.codexusageviewer.widget',
      'INFOPLIST_FILE' => "Config/#{target.name}-Info.plist",
      'CODE_SIGN_ENTITLEMENTS' => "Config/#{target.name}.entitlements",
      'SWIFT_VERSION' => '5.0',
      'MACOSX_DEPLOYMENT_TARGET' => '27.0',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks'],
      'COMBINE_HIDPI_IMAGES' => 'YES'
    })
    if target == widget
      config.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
      config.build_settings['SKIP_INSTALL'] = 'YES'
    else
      config.build_settings['PRODUCT_NAME'] = 'Codex Usage Viewer'
      config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
      config.build_settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
    end
  end
end
helper_version_phase = helper.new_shell_script_build_phase('Derive helper version from Git')
helper_version_phase.shell_script = 'python3 "${SRCROOT}/scripts/version.py" --write-plist "${DERIVED_FILE_DIR}/CodexUsageViewerHelper-Info.plist" --plist-template "${SRCROOT}/Config/CodexUsageViewerHelper-Info.plist"'
helper_version_phase.input_paths = ['$(SRCROOT)/Config/CodexUsageViewerHelper-Info.plist', '$(SRCROOT)/VERSION', '$(SRCROOT)/scripts/version.py']
helper_version_phase.output_paths = ['$(DERIVED_FILE_DIR)/CodexUsageViewerHelper-Info.plist']
helper_version_phase.always_out_of_date = '1'
helper.build_phases.delete(helper_version_phase)
helper.build_phases.unshift(helper_version_phase)
helper.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.inndevs.codexusageviewer.helper',
    'INFOPLIST_FILE' => '$(DERIVED_FILE_DIR)/CodexUsageViewerHelper-Info.plist',
    'CREATE_INFOPLIST_SECTION_IN_BINARY' => 'YES',
    'CODE_SIGN_ENTITLEMENTS' => 'Config/CodexUsageViewerHelper.entitlements',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks'],
    'SKIP_INSTALL' => 'YES'
  })
end
app.add_dependency(widget)
app.add_dependency(helper)
embed = app.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
embed.add_file_reference(widget.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
embed_helper = app.new_copy_files_build_phase('Embed Background Helper')
embed_helper.dst_subfolder_spec = '6'
embed_helper.add_file_reference(helper.product_reference).settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }
embed_agent = app.new_copy_files_build_phase('Embed Launch Agent')
embed_agent.dst_subfolder_spec = '1'
embed_agent.dst_path = 'Contents/Library/LaunchAgents'
embed_agent.add_file_reference(refs['Config/com.inndevs.codexusageviewer.helper.plist'])
version_phase = app.shell_script_build_phases.find { |phase| phase.name == 'Derive version from Git' }
app.build_phases.delete(version_phase)
app.build_phases << version_phase

if Dir.exist?('Tests/UI')
  ui = project.new_target(:ui_test_bundle, 'CodexUsageViewerUITests', :osx, '27.0')
  ui.add_dependency(app)
  Dir.glob('Tests/UI/*.swift').each { |path| ui.source_build_phase.add_file_reference(groups['Tests'].new_file(path.sub('Tests/', ''))) }
  ui.build_configurations.each do |config|
    config.build_settings.merge!({ 'PRODUCT_BUNDLE_IDENTIFIER' => 'com.inndevs.codexusageviewer.uitests', 'GENERATE_INFOPLIST_FILE' => 'YES', 'TEST_TARGET_NAME' => 'CodexUsageViewer', 'CODE_SIGN_IDENTITY' => 'Apple Development', 'SWIFT_VERSION' => '5.0', 'MACOSX_DEPLOYMENT_TARGET' => '27.0' })
  end
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(ui) if defined?(ui) && ui
scheme.save_as('CodexUsageViewer.xcodeproj', 'CodexUsageViewer', true)
puts 'Generated CodexUsageViewer.xcodeproj'
