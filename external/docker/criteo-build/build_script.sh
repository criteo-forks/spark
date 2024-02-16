set -x
set -e

MAVEN_USER=$1
MAVEN_PASSWORD=$2
SCALA_RELEASE=$3
SPARK_RELEASE=$4
NEXUS_ARTIFACT_URL=$5
NEXUS_PYPY_URL=$6
TIMESTAMP=$7

for var in "$MAVEN_USER" "$MAVEN_PASSWORD" "$SCALA_RELEASE" "$SPARK_RELEASE" "$NEXUS_ARTIFACT_URL" "$NEXUS_PYPY_URL" "$TIMESTAMP"; do
    if [ -z "$var" ]; then
        echo "Missing arguments"
        exit 1
    fi
done

TWINE_USERNAME=$MAVEN_USER
TWINE_PASSWORD=$MAVEN_PASSWORD

# Load HDP_VERSION and HIVE_VERSION
source external/docker/criteo-build/build_config.sh

deploy_python()
{
  pyspark_version=$1
  sed -i "s/__version__: str = \\\".*\\\"/__version__: str = \\\"${pyspark_version}\\\"/g" python/pyspark/version.py
  python -m venv venv
  source venv/bin/activate
  pip install --upgrade pip
  pip install -r python/requirements.txt
  cd python
  python setup.py bdist_wheel
  twine upload dist/pyspark*whl -u ${TWINE_USERNAME} -p ${TWINE_PASSWORD} --skip-existing --repository-url "${NEXUS_PYPY_URL}/"
  python setup.py clean --all
  cd $OLDPWD
}

VERSION_SUFFIX="criteo-${TIMESTAMP}"

if [ ${SCALA_RELEASE} == "2.12" ]; then
    ./dev/change-scala-version.sh 2.12
    MVN_SCALA_PROPERTY="-Pscala-2.12"
elif [ ${SCALA_RELEASE} == "2.11" ]; then
    ./dev/change-scala-version.sh 2.11
    MVN_SCALA_PROPERTY="-Pscala-2.11"
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
MVN_HDP_ARTIFACT_VERSION="${MVN_ARTIFACT_VERSION}-hadoop-${HDP_VERSION}"
PYTHON_PEX_VERSION="${SPARK_RELEASE}+criteo.scala.${SCALA_RELEASE}.${TIMESTAMP}"
PYTHON_HDP_PEX_VERSION="${SPARK_RELEASE}+criteo.scala.${SCALA_RELEASE}.hadoop.${HDP_VERSION}.${TIMESTAMP}"
SHUFFLE_SERVICE_JAR_FILE="dist/yarn/spark-${CRITEO_VERSION}-yarn-shuffle.jar"
MVN_COMMON_PROPERTIES="-Phive-provided -Phive-thriftserver -Pyarn -Dhive.version=${HIVE_VERSION} -Dhadoop.version=${HDP_VERSION} ${MVN_SCALA_PROPERTY}"
MVN_COMMON_DEPLOY_FILE_PROPERTIES="-Durl=${NEXUS_ARTIFACT_URL} -DrepositoryId=criteo -Dcriteo.repo.username=${MAVEN_USER} -Dcriteo.repo.password=${MAVEN_PASSWORD} -DretryFailedDeploymentCount=3"

# do some house cleaning
mvn --no-transfer-progress clean
rm -f spark-*.tgz
rm -f dist/python/dist/*
rm -f python/dist/*

# change version
mvn --no-transfer-progress versions:set -DnewVersion=${CRITEO_VERSION}

# Build distribution with hadoop
./dev/make-distribution.sh --pip --name ${SCALA_RELEASE}-${HDP_VERSION} --tgz -ntp ${MVN_COMMON_PROPERTIES}

# tgz artifact deployment
mvn deploy:deploy-file \
    --batch-mode \
    -DgroupId=com.criteo.tarballs \
    -DartifactId=spark \
    -Dversion=${MVN_HDP_ARTIFACT_VERSION} \
    -Dpackaging=tar.gz \
    -Dfile=${SPARK_HDP_ARTIFACT_FILE} \
    ${MVN_COMMON_DEPLOY_FILE_PROPERTIES}

deploy_python $PYTHON_HDP_PEX_VERSION

# Build distribution without hadoop
./dev/make-distribution.sh --pip --name ${SCALA_RELEASE} --tgz -ntp ${MVN_COMMON_PROPERTIES} -Phadoop-provided
# tgz artifact deployment
mvn deploy:deploy-file \
    --batch-mode \
    -DgroupId=com.criteo.tarballs \
    -DartifactId=spark \
    -Dversion=${MVN_ARTIFACT_VERSION} \
    -Dpackaging=tar.gz \
    -Dfile=${SPARK_ARTIFACT_FILE} \
    ${MVN_COMMON_DEPLOY_FILE_PROPERTIES}

# Create archive with jars only
cd dist/jars && tar -czf ${OLDPWD}/${SPARK_JARS_ARTIFACT_FILE} *.jar; cd $OLDPWD

# Deploy tgz jars only artifact
mvn deploy:deploy-file \
    --batch-mode \
    -DgroupId=com.criteo.tarballs \
    -DartifactId=spark-jars \
    -Dversion=${MVN_ARTIFACT_VERSION} \
    -Dpackaging=tar.gz \
    -Dfile=${SPARK_JARS_ARTIFACT_FILE} \
    ${MVN_COMMON_DEPLOY_FILE_PROPERTIES}

# shuffle service deployment
mvn deploy:deploy-file \
    --batch-mode \
    -DgroupId=org.apache.spark \
    -DartifactId=yarn-shuffle_${SCALA_RELEASE} \
    -Dversion=${CRITEO_VERSION} \
    -Dpackaging=jar \
    -Dfile=${SHUFFLE_SERVICE_JAR_FILE} \
    ${MVN_COMMON_DEPLOY_FILE_PROPERTIES}

# jar artifacts (for parent poms) deployment
mvn deploy \
    --batch-mode \
    ${MVN_COMMON_PROPERTIES} \
    -Phadoop-provided \
    -DaltDeploymentRepository=criteo::default::${NEXUS_ARTIFACT_URL} \
    -Dcriteo.repo.username=${MAVEN_USER} \
    -Dcriteo.repo.password=${MAVEN_PASSWORD} \
    -DskipTests


# python deployment
deploy_python $PYTHON_PEX_VERSION