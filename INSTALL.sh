mkdir -p ~/.stardict/dic
wget https://gh-proxy.com/https://github.com/skywind3000/ECDICT/releases/download/1.0.28/ecdict-stardict-28.zip
unzip ecdict-stardict-28.zip -d ~/.stardict/dic/
sdcv --list-dicts 
