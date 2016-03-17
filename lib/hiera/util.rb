class Hiera

  # Matches a key that is quoted using a matching pair of either single or double quotes.
  QUOTED_KEY = /^(?:"([^"]+)"|'([^']+)')$/

  module Util
    module_function

    def posix?
      require 'etc'
      Etc.getpwuid(0) != nil
    end

    def microsoft_windows?
      return false unless file_alt_separator

      begin
        require 'win32/dir'
        true
      rescue LoadError => err
        warn "Cannot run on Microsoft Windows without the win32-dir gem: #{err}"
        false
      end
    end

    def config_dir
      if microsoft_windows?
         File.join(common_appdata, 'PuppetLabs', 'code')
      else
        '/etc/puppetlabs/code'
      end
    end

    def var_dir
      if microsoft_windows?
        File.join(common_appdata, 'PuppetLabs', 'code', 'environments' , '%{environment}' , 'hieradata')
      else
        '/etc/puppetlabs/code/environments/%{environment}/hieradata'
      end
    end

    def file_alt_separator
      File::ALT_SEPARATOR
    end

    def common_appdata
      Dir::COMMON_APPDATA
    end
  end
end

