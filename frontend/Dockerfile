FROM swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/nginx:alpine3.20

# 也就是这几行，确保所有静态资源都被复制进去
COPY default.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
# 新增下面这一行，把背景图复制进去
COPY bg /usr/share/nginx/html/bg/
