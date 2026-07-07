# ap-gateway-operator

This directory contains the build script and related files for the ap-gateway-operator image, which is a main operator of the Automation Platform. The build process involves extracting the operator source code from a source-bundle OCI image, applying necessary patches, and preparing the CRDs for deployment.
AP(AAP) Gateway Operator is the only component that sources are distributed without the specified license. The source code is available in the source-bundle OCI image, and the build script extracts the relevant parts to create the operator image and CRDs.
