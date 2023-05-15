set -x

MAVEN_USER=$1
MAVEN_PASSWORD=$2
TWINE_USERNAME=$MAVEN_USER
TWINE_PASSWORD=$MAVEN_PASSWORD
SCALA_RELEASE=$3
SPARK_RELEASE=$4
NEXUS_ARTIFACT_URL=$5
NEXUS_PYPY_URL=$6

# Load HDP_VERSION and HIVE_VERSION
source external/docker/criteo-build/build_config.sh

TIMESTAMP=$(date -u +%Y%m%d%H%M%S)
VERSION_SUFFIX="criteo-${TIMESTAMP}"

if [ ${SCALA_RELEASE} == "2.12" ]; then
    ./dev/change-scala-version.sh 2.12
    MVN_SCALA_PROPERTY="-Pscala-2.12"
elif [ ${SCALA_RELEASE} == "2.11" ]; then
    ./dev/change-scala-version.sh 2.11
    MVN_SCALA_PROPERTY="-Dscala-2.11"
else
    echo "[ERROR] Scala release not provided"
    exit 1
fi

SPARK_VERSION="$(mvn org.apache.maven.plugins:maven-help-plugin:evaluate -Dexpression=project.version -q -DforceStdout)"
CRITEO_VERSION="${SPARK_VERSION}-${VERSION_SUFFIX}"
SPARK_ARTIFACT_FILE="spark-${CRITEO_VERSION}-bin-${SCALA_RELEASE}.tgz"
SPARK_HDP_ARTIFACT_FILE="spark-${CRITEO_VERSION}-bin-${SCALA_RELEASE}-${HDP_VERSION}.tgz"
SPARK_JARS_ARTIFACT_FILE="spark-${CRITEO_VERSION}-jars-${SCALA_RELEASE}.tgz"
MVN_ARTIFACT_VERSION="${CRITEO_VERSION}-${SCALA_RELEASE}"
MVN_HDP_ARTIFACT_VERSION="${MVN_ARTIFACT_VERSION}-${HDP_VERSION}"
SHUFFLE_SERVICE_JAR_FILE="dist/yarn/spark-${CRITEO_VERSION}-yarn-shuffle.jar"
MVN_COMMON_PROPERTIES="-Dhive.version=${HIVE_VERSION} ${MVN_SCALA_PROPERTY}"
MVN_COMMON_PROPERTIES_NO_TESTS="${MVN_COMMON_PROPERTIES} -DskipTests"
MVN_COMMON_NEXUS_PROPERTIES="-DrepositoryId=criteo -Dcriteo.repo.username=${MAVEN_USER} -Dcriteo.repo.password=${MAVEN_PASSWORD} -DretryFailedDeploymentCount=3"

# do some house cleaning
mvn clean
rm -f spark-*.tgz
rm -f dist/python/dist/*
rm -f python/dist/*

# change version
mvn versions:set -DnewVersion=${CRITEO_VERSION}

# Build distribution with hadoop
./dev/make-distribution.sh --pip --name ${SCALA_RELEASE}-${HDP_VERSION} --tgz -Phive -Phive-thriftserver -Pyarn -Dhadoop.version=${HDP_VERSION} ${MVN_COMMON_PROPERTIES_NO_TESTS}

# tgz artifact deployment
mvn deploy:deploy-file \\
    --batch-mode \\
    -DgroupId=com.criteo.tarballs \\
    -DartifactId=spark \\
    -Dversion=${MVN_HDP_ARTIFACT_VERSION} \\
    -Dpackaging=tar.gz \\
    -Dfile=${SPARK_HDP_ARTIFACT_FILE} \\
    -Durl=${NEXUS_ARTIFACT_URL} \\
    ${MVN_COMMON_NEXUS_PROPERTIES}

# Build distribution without hadoop
./dev/make-distribution.sh --pip --name ${SCALA_RELEASE} --tgz -Phive -Phive-thriftserver -Pyarn -Phadoop-provided ${MVN_COMMON_PROPERTIES}
# tgz artifact deployment
mvn deploy:deploy-file \\
    --batch-mode \\
    -DgroupId=com.criteo.tarballs \\
    -DartifactId=spark \\
    -Dversion=${MVN_ARTIFACT_VERSION} \\
    -Dpackaging=tar.gz \\
    -Dfile=${SPARK_ARTIFACT_FILE} \\
    -Durl=${NEXUS_ARTIFACT_URL} \\
    ${MVN_COMMON_NEXUS_PROPERTIES}

# Create archive with jars only
cd dist/jars && tar -czf ${OLDPWD}/${SPARK_JARS_ARTIFACT_FILE} dist/jars; cd $OLDPWD

# Deploy tgz jars only artifact
mvn deploy:deploy-file \\
    --batch-mode \\
    -DgroupId=com.criteo.tarballs \\
    -DartifactId=spark \\
    -Dversion=${MVN_ARTIFACT_VERSION} \\
    -Dpackaging=tar.gz \\
    -Dfile=${SPARK_JARS_ARTIFACT_FILE} \\
    -Durl=${NEXUS_ARTIFACT_URL} \\
    ${MVN_COMMON_NEXUS_PROPERTIES}

# shuffle service deployment
mvn deploy:deploy-file \\
    --batch-mode \\
    -DgroupId=org.apache.spark \\
    -DartifactId=yarn-shuffle_${SCALA_RELEASE} \\
    -Dversion=${CRITEO_VERSION} \\
    -Dpackaging=jar \\
    -Dfile=${SHUFFLE_SERVICE_JAR_FILE} \\
    -Durl=${NEXUS_ARTIFACT_URL} \\
    ${MVN_COMMON_NEXUS_PROPERTIES}

# jar artifacts (for parent poms) deployment
mvn jar:jar deploy:deploy \\
    --batch-mode \\
    -Phive -Phive-thriftserver \\
    -Pyarn \\
    -Phadoop-provided \\
    -DaltDeploymentRepository=criteo::${NEXUS_ARTIFACT_URL} \\
    ${MVN_COMMON_NEXUS_PROPERTIES}

# python deployment
pyspark_version=${SPARK_RELEASE}+criteo_${SCALA_RELEASE}.${TIMESTAMP}
sed -i "s/__version__ = \\\".*\\\"/__version__ = \\\"${pyspark_version}\\\"/g" python/pyspark/version.py
python2.7 -m venv venv
source venv/bin/activate
pip install -r python/requirements.txt
cd python
python setup.py bdist_wheel
twine upload dist/pyspark*whl -u ${TWINE_USERNAME} -p ${TWINE_PASSWORD} --skip-existing --repository-url "${NEXUS_PYPY_URL}/"