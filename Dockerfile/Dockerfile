FROM debian:bullseye

ARG USER
ARG EMAIL
ARG UID
ARG GID

# Environment variables
#---------------------#
ENV DEBIAN_FRONTEND noninteractive
ENV SRC_DIR /home/$USER/src
ENV OUT_DIR /home/$USER/src/out
ENV CCACHE_DIR /home/$USER/ccache
ENV CCACHE_EXEC /usr/bin/ccache
ENV LOGS_DIR /home/$USER/logs

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

# Create volum directories
#------------------------#
RUN mkdir -p $SRC_DIR/ $OUT_DIR/ $CCACHE_DIR/ $LOGS_DIR/

# Install build dependencies
#--------------------------#
RUN apt-get -qq update
RUN apt-get -qqy upgrade

RUN apt-get install -y --no-install-recommends \
        bc bison build-essential ccache curl flex openssl ca-certificates \
        g++-multilib gcc-multilib git gnupg gperf imagemagick \
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
ENV PATH /home/$USER/bin:$PATH
RUN mkdir -p /home/$USER/bin/
ADD https://storage.googleapis.com/git-repo-downloads/repo /home/$USER/bin/repo
RUN chmod +x /home/$USER/bin/repo

# Run everything as non-root
#--------------------------#
RUN chown --changes --silent --recursive $USER:$USER /home/$USER/
USER $USER

# Set-up configs
#--------------#
RUN git config --global user.name $USER
RUN git config --global user.email $EMAIL

# Set work directory
#------------------#
WORKDIR $SRC_DIR
