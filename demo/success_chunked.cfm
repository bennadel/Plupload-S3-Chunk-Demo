<cfscript>
	
	// Include the Amazon Web Service (AWS) S3 credentials.
	include "aws-credentials.cfm";

	// Include some utility methods to make the AWS interactions easier.
	include "udf.cfm";


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //


	// When the chunks have all been uploaded to the Amazon S3 bucket, we need to know 
	// the base resource URL (ie, the parts before the .0, .1, .2, etc) and the number
	// of chunks that were uploaded. All of the chunks are going to be merged together
	// to re-create the master file on S3.
	// --
	// NOTE: This values will NOT start with a leading slash.
	param name="url.baseKey" type="string";

	// I am the number of chunks used to POST the file.
	param name="url.chunks" type="numeric";

	// Since the key may have characters that required url-encoding, we have to re-encode
	// the key or our signature may not match.
	urlEncodedKey = urlEncodedFormat( url.baseKey );

	// When we rebuild the master file from the chunks, we'll have to make a number of 
	// requests to the file we want to create, PLUS some stuff. Let's create the base
	// resource on which we can build.
	baseResource = ( "/" & aws.bucket & "/" & urlEncodedKey );


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //


	// Now, we need to initiate the re-creation of the master file. This, unfortunately,
	// is going to require a number of steps. We are going to leverage the "Multipart
	// Upload" S3 feature which allows a single file to be uploaded across several 
	// different HTTP requests; however, since our "chunks" are already on S3, we're 
	// going to use the "Upload Part - Copy" action to consume the chunks that we already
	// uploaded.

	// First, we need to initiate the multipart upload and get our unique upload ID. To
	// do this, we have to append "?uploads" to the base resource (ie, the resource we
	// want to create).
	resource = ( baseResource & "?uploads" );

	// A timestamp is required for all authenticated requests.
	currentTime = getHttpTimeString( now() );

	signature = generateSignature(
		secretKey = aws.secretKey,
		method = "POST",
		createdAt = currentTime,
		resource = resource
	);

	// Send request to Amazon S3.
	initiateUpload = new Http( 
		method = "post",
		url = "https://s3.amazonaws.com#resource#"
	);

	initiateUpload.addParam(
		type = "header",
		name = "authorization", 
		value = "AWS #aws.accessID#:#signature#" 
	);

	initiateUpload.addParam(
		type = "header",
		name = "date",
		value = currentTime 
	);

	// The response comes back as XML.
	response = xmlParse( initiateUpload.send().getPrefix().fileContent );

 	// ... we need to extract the "uploadId" value.
	uploadID = xmlSearch( response, "string( //*[ local-name() = 'UploadId' ] )" );


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //


	// Now that we have the our upload ID, we can begin to build up the master file, one
	// chunk at a time. When we do this, we have to make sure to keep track of the ETag
	// returned from Amazon - we'll need it to finalize the upload in the next step.
	etags = [];

	// As we are looping over the chunks, note that the Plupload / JavaScript chunks are
	// ZERO-based; but, the Amazon parts are ONE-based.
	// --
	// NOTE: 
	for ( i = 0 ; i < url.chunks ; i++ ) {

		// Indicate which chunk we're dealing with.
		resource = ( baseResource & "?partNumber=#( i + 1 )#&uploadId=#uploadID#" );

		// A timestamp is required for all authenticated requests.
		currentTime = getHttpTimeString( now() );

		// Notice that we're using the "x-amz-copy-source" header. This tells Amazon S3
		// that the incoming chunk ALREADY resides on S3. And, in fact, we're providing
		// the key to the Plupload chunk.
		signature = generateSignature(
			secretKey = aws.secretKey,
			method = "PUT",
			createdAt = currentTime,
			amazonHeaders = [
				"x-amz-copy-source:#baseResource#.#i#"
			],
			resource = resource
		);

		// Send request to Amazon S3.
		initiateUpload = new Http( 
			method = "put",
			url = "https://s3.amazonaws.com#resource#"
		);

		initiateUpload.addParam(
			type = "header",
			name = "authorization", 
			value = "AWS #aws.accessID#:#signature#" 
		);
		
		initiateUpload.addParam(
			type = "header",
			name = "date", 
			value = currentTime 
		);
		
		initiateUpload.addParam(
			type = "header", 
			name = "x-amz-copy-source", 
			value = "#baseResource#.#i#" 
		);

		// The response comes back as XML.
		response = xmlParse( initiateUpload.send().getPrefix().fileContent );

		// ... we need to extract the ETag value.
		etag = xmlSearch( response, "string( //*[ local-name() = 'ETag' ] )" );

		arrayAppend( etags, etag );

	}


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //


	// Now that we have told Amazon S3 about the location of the chunks that we uploaded,
	// we can finalize the multi-part upload. When doing this, Amazon S3 will concatenate
	// all of the chunks back into the master file.

	// NOTE: Parts are one-based (not zero-based).
	xml = [ "<CompleteMultipartUpload>" ];

	for ( i = 0 ; i < url.chunks ; i++ ) {

		arrayAppend(
			xml,
			"<Part>" &
				"<PartNumber>#( i + 1 )#</PartNumber>" &
				"<ETag>#etags[ i + 1 ]#</ETag>" &
			"</Part>"
		);

	}

	arrayAppend( xml, "</CompleteMultipartUpload>" );

	body = arrayToList( xml, chr( 10 ) );

	// Define the resource that Amazon S3 should construct with the given upload ID.
	resource = ( baseResource & "?uploadId=#uploadID#" );

	// A timestamp is required for all authenticated requests.
	currentTime = getHttpTimeString( now() );

	signature = generateSignature(
		secretKey = aws.secretKey,
		method = "POST",
		createdAt = currentTime,
		resource = resource
	);

	// Send request to Amazon S3.
	finalizeUpload = new Http( 
		method = "post",
		url = "https://s3.amazonaws.com#resource#"
	);

	finalizeUpload.addParam( 
		type = "header",
		name = "authorization", 
		value = "AWS #aws.accessID#:#signature#" 
	);
	
	finalizeUpload.addParam( 
		type = "header", 
		name = "date",
		value = currentTime 
	);
	
	finalizeUpload.addParam( 
		type = "header", 
		name = "content-length", 
		value = len( body ) 
	);
	
	finalizeUpload.addParam( 
		type = "body",
		value = body 
	);

	response = finalizeUpload.send().getPrefix();

	// Make sure that if the build failed, then we don't delete the chunk files. IE,
	// make sure we don't get to the next step.
	if ( ! reFind( "^2\d\d", response.statusCode ) ) {

		throw( type = "BuildFailed" );

	}


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //


	// At this point, we have collected the chunk files and merged them back into a
	// mastder file on Amazon S3. Now, we can safely delete the chunk files. For this, 
	// I'm using Amazon S3's multi-object delete.
	// --
	// NOTE: I CANNOT ACTUALLY GET THIS TO WORK. THE RESPONSE SEEMS TO INDICATE THAT 
	// THE OBJECTS WHERE DELETED; HOWEVER, WHEN I BROWSE MY BUCKET, THE OBJECTS STILL
	// SEEM TO EXIST AND CAN BE ACCESSED (BY ME). NO MATTER WHAT COMBINATION OF <Key>
	// VALUES I TRIED, NOTHING SEEMED TO WORK. AHHHHHHHH!!!!!!!
	// --
	xml = [ "<Delete>" ];

	// Add each object key to the delete request.
	for ( i = 0 ; i < url.chunks ; i++ ) {

		arrayAppend(
			xml,
			"<Object>" &
				"<Key>/#aws.bucket#/#url.baseKey#.#i#</Key>" &
			"</Object>"
		);

	}

	arrayAppend( xml, "</Delete>" );

	body = arrayToList( xml, chr( 10 ) );

	// Generate the MD5 hash to ensure the integirty of the request.
	md5Hash = generateMd5Hash( body );

	// A timestamp is required for all authenticated requests.
	currentTime = getHttpTimeString( now() );

	// For multi-object delete, the resource simply points to our bucket.
	resource = ( "/" & aws.bucket & "/?delete" );

	signature = generateSignature(
		secretKey = aws.secretKey,
		method = "POST",
		md5Hash = md5Hash,
		contentType = "application/xml",
		createdAt = currentTime,
		resource = resource
	);

	// Send request to Amazon S3.
	deleteChunks = new Http( 
		method = "post",
		url = "https://s3.amazonaws.com#resource#"
	);

	deleteChunks.addParam( 
		type = "header",
		name = "authorization", 
		value = "AWS #aws.accessID#:#signature#" 
	);
	
	deleteChunks.addParam( 
		type = "header", 
		name = "date",
		value = currentTime 
	);
	
	deleteChunks.addParam( 
		type = "header", 
		name = "content-type", 
		value = "application/xml"
	);

	deleteChunks.addParam( 
		type = "header", 
		name = "content-length", 
		value = len( body ) 
	);

	deleteChunks.addParam( 
		type = "header", 
		name = "content-md5", 
		value = md5Hash
	);

	deleteChunks.addParam( 
		type = "header", 
		name = "accept", 
		value = "*/*"
	);
	
	deleteChunks.addParam( 
		type = "body",
		value = body 
	);

	response = deleteChunks.send().getPrefix();


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //


	// Now that we've re-created the master file and cleaned up (supposedly) after 
	// ourselves, we can forward the user to a pre-signed URL of the file on S3.

	// The URL will only be valid for a short amount of time.
	nowInSeconds = fix( getTickCount() / 1000 );

	// Add 10 seconds.
	expirationInSeconds = ( nowInSeconds + 20 );

	// Sign the request.
	signature = generateSignature(
		secretKey = aws.secretKey,
		method = "GET",
		expiresAt = expirationInSeconds,
		resource = baseResource
	);

	// Prepare the signature for use in a URL (to make sure none of the characters get 
	// transported improperly).
	urlEncodedSignature = urlEncodedFormat( signature );


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //
	

	// Direct to the pre-signed URL.
	location( 
		url = "https://s3.amazonaws.com#baseResource#?AWSAccessKeyId=#aws.accessID#&Expires=#expirationInSeconds#&Signature=#urlEncodedSignature#", 
		addToken = false 
	);

</cfscript>