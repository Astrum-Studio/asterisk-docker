FROM debian:12-slim

ARG ASTERISK_VERSION=21
ARG FREEPBX_BRANCH=release/17.0
ARG FREEPBX_TARBALL_URL=http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest-EDGE.tgz

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Europe/Moscow \
    HTTP_PORT=8080 \
    FREEPBX_DB_USER=freepbx \
    FREEPBX_DB_PASS=freepbx \
    FREEPBX_DB_PORT=3307 \
    RTP_START=10000 \
    RTP_FINISH=20000

RUN apt-get update && apt-get install -y --no-install-recommends \
    apache2-utils \
    build-essential \
    ca-certificates \
    cron \
    curl \
    ffmpeg \
    gettext-base \
    git \
    gnupg \
    lame \
    libasound2-dev \
    libcurl4-openssl-dev \
    libedit-dev \
    libical-dev \
    libicu-dev \
    libjansson-dev \
    libncurses5-dev \
    libneon27-dev \
    libnewt-dev \
    libogg-dev \
    libsnmp-dev \
    libspandsp-dev \
    libsqlite3-dev \
    libsrtp2-dev \
    libssl-dev \
    liburiparser-dev \
    libvorbis-dev \
    libxml2-dev \
    locales \
    mariadb-client \
    mpg123 \
    nginx \
    nodejs \
    npm \
    openssl \
    php8.2 \
    php8.2-bcmath \
    php8.2-cli \
    php8.2-curl \
    php8.2-fpm \
    php8.2-gd \
    php8.2-intl \
    php8.2-mbstring \
    php8.2-mysql \
    php8.2-soap \
    php8.2-xml \
    php8.2-zip \
    php-pear \
    pkg-config \
    procps \
    sox \
    subversion \
    supervisor \
    odbc-mariadb \
    unixodbc \
    unixodbc-dev \
    uuid-dev \
    wget \
  && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    cd /usr/src; \
    wget -O asterisk-current.tar.gz "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}-current.tar.gz"; \
    tar xzf asterisk-current.tar.gz; \
    cd asterisk-${ASTERISK_VERSION}.*; \
    contrib/scripts/get_mp3_source.sh; \
    ./configure --libdir=/usr/lib/asterisk --with-pjproject-bundled --with-jansson-bundled; \
    make menuselect.makeopts; \
    menuselect/menuselect --enable format_mp3 menuselect.makeopts; \
    make -j"$(nproc)"; \
    make install; \
    make samples; \
    cd /; \
    rm -rf /usr/src/asterisk*

RUN set -eux; \
    echo "/usr/lib/asterisk" > /etc/ld.so.conf.d/asterisk.conf; \
    ldconfig; \
    /usr/sbin/asterisk -V

RUN set -eux; \
    mkdir -p /usr/local/share/asterisk-config-defaults; \
    cp -a /etc/asterisk/. /usr/local/share/asterisk-config-defaults/

RUN set -eux; \
    groupadd -r asterisk; \
    useradd -r -d /var/lib/asterisk -g asterisk asterisk; \
    usermod -aG audio,dialout asterisk; \
    mkdir -p /var/lib/asterisk /var/spool/asterisk/tmp /var/log/asterisk /etc/asterisk /var/www/html; \
    chown -R asterisk:asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /etc/asterisk

RUN set -eux; \
    mkdir -p /usr/src/freepbx; \
    wget -O /tmp/freepbx.tgz "${FREEPBX_TARBALL_URL}"; \
    tar xzf /tmp/freepbx.tgz -C /usr/src/freepbx --strip-components=1; \
    rm -f /tmp/freepbx.tgz; \
    sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php/8.2/fpm/php.ini; \
    sed -i 's/memory_limit = .*/memory_limit = 256M/' /etc/php/8.2/fpm/php.ini; \
    sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' /etc/php/8.2/fpm/php.ini; \
    sed -i 's/post_max_size = .*/post_max_size = 64M/' /etc/php/8.2/fpm/php.ini; \
    sed -i 's/^user = .*/user = asterisk/' /etc/php/8.2/fpm/pool.d/www.conf; \
    sed -i 's/^group = .*/group = asterisk/' /etc/php/8.2/fpm/pool.d/www.conf; \
    sed -i 's/^listen.owner = .*/listen.owner = asterisk/' /etc/php/8.2/fpm/pool.d/www.conf; \
    sed -i 's/^listen.group = .*/listen.group = asterisk/' /etc/php/8.2/fpm/pool.d/www.conf; \
    sed -i 's/^;listen.mode = .*/listen.mode = 0666/' /etc/php/8.2/fpm/pool.d/www.conf; \
    rm -f /etc/nginx/sites-enabled/default; \
    for f in /usr/src/freepbx/amp_conf/bin/*; do \
      ln -sf "$f" "/usr/sbin/$(basename "$f")"; \
    done

COPY docker/freepbx-nginx.conf.template /etc/nginx/templates/freepbx.conf.template
COPY docker/supervisord.conf /etc/supervisor/conf.d/freepbx.conf
COPY docker/ensure-ami.sh /usr/local/bin/freepbx-ensure-ami
COPY docker/ensure-odbc.sh /usr/local/bin/freepbx-ensure-odbc
COPY docker/ensure-freepbx-layout.sh /usr/local/bin/freepbx-ensure-layout
COPY docker/sync-freepbx-runtime.sh /usr/local/bin/freepbx-sync-runtime
COPY docker/ensure-call-recording.sh /usr/local/bin/freepbx-ensure-call-recording
COPY docker/entrypoint.sh /usr/local/bin/freepbx-entrypoint
COPY docker/post-start.sh /usr/local/bin/freepbx-post-start

RUN chmod +x \
    /usr/local/bin/freepbx-ensure-ami \
    /usr/local/bin/freepbx-ensure-odbc \
    /usr/local/bin/freepbx-ensure-layout \
    /usr/local/bin/freepbx-sync-runtime \
    /usr/local/bin/freepbx-ensure-call-recording \
    /usr/local/bin/freepbx-entrypoint \
    /usr/local/bin/freepbx-post-start \
  && mkdir -p /var/lib/asterisk/bin /var/lib/asterisk/agi-bin

EXPOSE 8080/tcp 5060/tcp 5060/udp 10000-20000/udp

VOLUME ["/data", "/etc/asterisk", "/var/lib/asterisk/sounds/custom", "/var/spool/asterisk/monitor", "/var/spool/asterisk/voicemail", "/certs", "/var/log"]

ENTRYPOINT ["/usr/local/bin/freepbx-entrypoint"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/conf.d/freepbx.conf"]
