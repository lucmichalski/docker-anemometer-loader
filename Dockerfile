FROM mysql:5.6

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get -yq install \
    libdbi-perl \
    libmysqlclient18 \
    libdbd-mysql-perl \
    openssh-client \
    wget

WORKDIR /tmp

# a collection script based largely on the script shipping with Box Anemometer 
COPY conf/anemometer_collect.sh anemometer_collect.sh

# my.cnf for the anemometer mysql instance
COPY conf/anem_mysql.cnf anem_mysql.cnf

# pull down the pt-query-digest tool
RUN wget -P /usr/local/bin --no-check-certificate percona.com/get/pt-query-digest \
    && chmod +x /usr/local/bin/pt-query-digest

# running the container should just call the script
ENTRYPOINT ["./anemometer_collect.sh"]

# by default show the help, callers should pass params in their run command
CMD ["--help"]
