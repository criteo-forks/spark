#!/usr/bin/env bash

# You can run tests for a module only by specifying -pl <module>
# as argument to this script, or some specific test by passing
# -Dtest=... (see surefire documentation).

source `dirname "$0"`/criteo-spark-env.sh

export _JAVA_OPTIONS="-Xss2048k -Dspark.buffer.pageSize=1048576 -Xmx4g"

SPARK_TEST_TAGS_EXCLUDED_DEFAULT=org.apache.spark.tags.DockerTest
SPARK_TEST_TAGS_EXCLUDED=${SPARK_TEST_TAGS_EXCLUDED-${SPARK_TEST_TAGS_EXCLUDED_DEFAULT}}

$SPARK_HOME/build/mvn $CRITEO_SPARK_PROFILES                                   \
    -Dtest.exclude.tags=$SPARK_TEST_TAGS_EXCLUDED                              \
    -DfailIfNoTests=false --fail-at-end                                        \
    test "$@"
