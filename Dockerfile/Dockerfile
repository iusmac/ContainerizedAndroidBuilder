FROM debian:bullseye

LABEL maintainer="iusmac <iusico.maxim@libero.it>"

ARG EMAIL
ARG UID
ARG GID

# Environment variables
#---------------------#
ENV USER android
ENV DEBIAN_FRONTEND noninteractive
ENV SRC_DIR /mnt/src
ENV OUT_DIR /mnt/out
ENV CCACHE_DIR /mnt/ccache
ENV CCACHE_EXEC /usr/bin/ccache
ENV LOGS_DIR /mnt/logs
ENV ZIP_DIR /mnt/zips
ENV TERM xterm-256color

# Create host user
#----------------#
RUN groupadd --gid $GID $USER && \
    useradd --uid $UID \
        --gid $GID \
        --no-log-init \
        --create-home \
        --shell /bin/bash \
        $USER

# Delcare volume list
#-------------------#
VOLUME $SRC_DIR
VOLUME $OUT_DIR
VOLUME $CCACHE_DIR
VOLUME $LOGS_DIR
VOLUME $ZIP_DIR

# Create volum directories
#------------------------#
RUN mkdir -p $SRC_DIR/ $OUT_DIR/ $CCACHE_DIR/ $LOGS_DIR/ $ZIP_DIR/

# Install build dependencies
#--------------------------#
RUN apt-get update
RUN apt-get -y upgrade

RUN apt-get install -y --no-install-recommends \
        bc bison build-essential ccache curl flex openssl ca-certificates \
        g++-multilib gcc-multilib git git-lfs gnupg gperf imagemagick \
        lib32ncurses5-dev lib32readline-dev lib32z1-dev liblz4-tool \
        libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev ssh \
        libwxgtk3.0-gtk3-dev libxml2 libxml2-utils lzop pngcrush \
        rsync schedtool squashfs-tools xsltproc zip unzip zlib1g-dev vim

# Force using python3
#-------------------#
RUN rm -f /usr/bin/python
RUN ln -s /usr/bin/python3 /usr/bin/python

# Download latest repo
#--------------------#
ADD https://storage.googleapis.com/git-repo-downloads/repo /usr/local/bin/repo
RUN chmod a+rwx /usr/local/bin/repo

# Run everything as non-root
#--------------------------#
RUN find /home/$USER/ /mnt -exec chown \
        --silent \
        --recursive \
        $USER:$USER \
        {} \+

USER $USER

# Set-up configs
#--------------#
RUN git config --global user.name $USER
RUN git config --global user.email $EMAIL
RUN echo 'source /mnt/.bashrc_extra/.bashrc_extra' > /home/$USER/.bash_aliases

# Set work directory
#------------------#
WORKDIR $SRC_DIR
