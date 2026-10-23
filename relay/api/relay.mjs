import {makeHandler} from '../src/http.mjs';import {getRelay} from '../src/firebase.mjs';
export default makeHandler(getRelay);
