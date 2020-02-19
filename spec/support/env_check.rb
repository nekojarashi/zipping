module EnvCheck
  def unzip_unavailable?
    system("which 2> /dev/null").nil? || !system("which unzip > /dev/null 2> /dev/null")
  end
end
