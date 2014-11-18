Name:       vaultaire-collector-ceilometer
Version:    0.1.0
Release:    0.0anchor%{?build_number}%{!?build_number:1}%{?dist}
Summary:    Vaultaire Publisher for Ceilometer

Group:      Development/Libraries
License:    BSD
URL:        https://github.com/anchor/vaultaire-collector-ceilometer
Source0:    vaultaire-collector-ceilometer-%{version}.tar.gz
Source1:    vaultaire-common.tar.gz
Source2:    marquise.tar.gz
Source3:    vaultaire-collector-common.tar.gz
BuildRoot:  %(mktemp -ud %{_tmppath}/%{name}-%{version}-%{release}-XXXXXX)

BuildRequires:  ghc >= 7.8.3
BuildRequires:  cabal-install
BuildRequires:  zeromq-devel >= 4.0.3
BuildRequires:  gmp-devel
BuildRequires:  zlib-devel
Requires:   gmp
Requires:   zlib
Requires:   zeromq >= 4.0.3

%description
vaultaire-collector-ceilometer reads metrics from a RabbitMQ queue, consolidates them and publishes them as vaultaire SimplePoints and SourceDicts

%global ghc_without_dynamic 1

%prep
%setup -n vaultaire-common -T -D -b 1
%setup -n marquise -T -D -b 2
%setup -n vaultaire-collector-common -T -D -b 3
%setup -T -D -b 0

%build
export LC_ALL=en_US.UTF-8
cabal list > /dev/null
sed -r -i "s,^(remote-repo: hackage.haskell.org.*)$,\1\nremote-repo: hackage.syd1.anchor.net.au:http://hackage.syd1.anchor.net.au/packages/archive," /home/jenkins/.cabal/config
cabal update
cabal sandbox init
cabal sandbox add-source ../vaultaire-common
cabal sandbox add-source ../marquise
cabal sandbox add-source ../vaultaire-collector-common
cabal install --only-dependencies
cabal build

%install
mkdir -p %{buildroot}/usr/bin
cp -v dist/build/vaultaire-collector-ceilometer/vaultaire-collector-ceilometer %{buildroot}%{_bindir}

%files
%defattr(-,root,root,-)

%{_bindir}/vaultaire-collector-ceilometer

%changelog
* Tue Nov 18 2014 Oswyn Brent <oswyn.brent@anchor.com.au> - 0.1.0-0.0anchor1
- initial build

