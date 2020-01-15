#!/bin/bash -ex

wget -nv https://services.gradle.org/distributions/gradle-6.0.1-bin.zip
sha256sum -c <<< 'd364b7098b9f2e58579a3603dc0a12a1991353ac58ed339316e6762b21efba44  gradle-6.0.1-bin.zip'
unzip -d /opt gradle-6.0.1-bin.zip
rm gradle-6.0.1-bin.zip
