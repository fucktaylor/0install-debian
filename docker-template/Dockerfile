FROM debian:sid

# Core build tools

RUN DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y build-essential lintian vim

# 0install build dependencies

RUN DEBIAN_FRONTEND=noninteractive apt-get install -y \
	ocaml-nox \
	ocaml-findlib \
	libyojson-ocaml-dev \
	libxmlm-ocaml-dev \
	make \
	liblwt-ocaml-dev \
	ocaml-dune \
	libounit-ocaml-dev \
	libcurl-ocaml-dev \
	libsha-ocaml-dev \
	libobus-ocaml-dev \
	liblablgtk3-ocaml-dev \
	devscripts \
	fakeroot \
	quilt \
	dh-make \
	less \
	dh-ocaml \
	ocamlbuild \
	libppxlib-ocaml-dev \
	liblwt-log-ocaml-dev \
	--no-install-recommends

# Run-time utilities (needed for testing)
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y unzip xdg-utils python3 ocaml-native-compilers

RUN useradd -U -u 1000 -m tal

USER tal
ENV EMAIL talex5@gmail.com
ENV GNUPGHOME /mnt/gnupg

WORKDIR /mnt
