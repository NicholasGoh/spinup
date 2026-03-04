FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl sudo ca-certificates bash ncurses-bin git tmux \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user with sudo
RUN useradd -m -s /bin/bash testuser \
    && echo "testuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/testuser

COPY bootstrap.sh /home/testuser/bootstrap.sh
COPY lib/ /home/testuser/lib/
RUN chmod +x /home/testuser/bootstrap.sh && chown -R testuser:testuser /home/testuser/bootstrap.sh /home/testuser/lib/

USER testuser
WORKDIR /home/testuser

ENTRYPOINT ["bash"]
