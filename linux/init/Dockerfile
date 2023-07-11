# 开箱即用的 C/C++ 开发环境
# docker build -t ubuntu_dev_cpp . --no-cache
# docker run -dit --name dev_cpp ubuntu_dev_cpp

FROM ubuntu:latest

COPY ./init.sh /root/init.sh
RUN chmod +x /root/init.sh && /root/init.sh

WORKDIR /home
CMD ["/bin/zsh"]
